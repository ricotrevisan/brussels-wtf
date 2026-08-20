defmodule BrusselsWtfWeb.ReviewInterfaceTest do
  use BrusselsWtfWeb.ConnCase, async: false

  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Review
  alias BrusselsWtf.Review.Actor

  setup %{conn: conn} do
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-08-20 12:00:00Z])
    actor = %Actor{id: "rico", role: :reviewer}
    context = build_context!()
    conn = conn |> init_test_session(%{}) |> BrusselsWtfWeb.ReviewAuth.log_in(actor)
    {:ok, conn: conn, actor: actor, context: context}
  end

  test "the filtered inbox and detail expose the complete review evidence chain", %{
    conn: conn,
    context: context
  } do
    inbox =
      get(
        conn,
        ~p"/review?kind=extraction&commune=#{context.commune.id}&status=open&generation=gen-1&age=7"
      )

    body = html_response(inbox, 200)
    assert body =~ "Native extraction quality failed"
    assert body =~ "Ixelles"
    assert body =~ "gen-1"

    inbox_document = LazyHTML.from_document(body)
    assert LazyHTML.text(inbox_document["thead"]) =~ "Affected record"
    assert LazyHTML.text(inbox_document["thead"]) =~ "Status / disposition"

    detail = get(recycle(inbox), ~p"/review/cases/#{context.review_case.id}")
    body = html_response(detail, 200)
    assert body =~ context.url
    assert body =~ context.version.sha256
    assert body =~ "redirected.example.test"
    assert body =~ "broken extraction"
    assert body =~ "Candidate title"
    assert body =~ "text_ratio"
    assert body =~ "too little text"
    assert body =~ "page 1"
    assert body =~ "fixture-poppler"
    assert body =~ "invalid_pdf"
    assert body =~ "rejected_pages"
    assert body =~ "duration_ms"
    assert body =~ "attempts"
    refute body =~ context.version.object_key
  end

  test "artifact previews require both a review session and a short-lived token", %{
    conn: conn,
    context: context
  } do
    detail = get(conn, ~p"/review/cases/#{context.review_case.id}")
    document = detail |> html_response(200) |> LazyHTML.from_document()

    [href] =
      LazyHTML.attribute(document["a[data-private-artifact]:not([data-artifact-kind])"], "href")

    preview = get(recycle(detail), href)
    assert response(preview, 200) == context.bytes
    assert get_resp_header(preview, "cache-control") == ["private, no-store"]
    refute href =~ context.version.object_key

    [derived_href] =
      LazyHTML.attribute(document["a[data-artifact-kind='derived']"], "href")

    derived_preview = get(recycle(detail), derived_href)
    assert response(derived_preview, 200) == context.derived_bytes
    refute derived_href =~ context.artifact.object_key

    anonymous = build_conn() |> get(href)
    assert redirected_to(anonymous) == ~p"/review/login"

    denied =
      get(
        recycle(detail),
        ~p"/review/artifacts/source-versions/#{context.version.id}?token=invalid"
      )

    assert response(denied, 404) == "Not found"
  end

  test "CSRF-protected action and note forms retain reviewer history", %{
    conn: conn,
    actor: actor,
    context: context
  } do
    detail = get(conn, ~p"/review/cases/#{context.review_case.id}")
    document = detail |> html_response(200) |> LazyHTML.from_document()

    [csrf] =
      LazyHTML.attribute(
        document["form[action$='/actions/retry'] input[name='_csrf_token']"],
        "value"
      )

    assert LazyHTML.attribute(
             document["form[action$='/actions/retry'] input[name='processor_name']"],
             "name"
           ) == []

    assert LazyHTML.attribute(
             document["form[action$='/actions/retry'] input[name='processor_version']"],
             "name"
           ) == []

    assert LazyHTML.attribute(
             document["form[action$='/actions/retry'] input[name='config_hash']"],
             "name"
           ) == []

    acted =
      detail
      |> recycle()
      |> post(~p"/review/cases/#{context.review_case.id}/actions/retry", %{
        "_csrf_token" => csrf,
        "note" => "retry with corrected configuration",
        "processor_name" => "native-extraction",
        "processor_version" => "2",
        "config_hash" => "corrected-fixture"
      })

    assert redirected_to(acted) == ~p"/review/cases/#{context.review_case.id}"
    reviewed = Review.get_review_case!(context.review_case.id, actor: actor)

    assert [%{action: :retry, actor_id: "rico", note: "retry with corrected configuration"}] =
             reviewed.actions

    retry_run =
      reviewed.source_version.processing_runs
      |> Enum.find(&(&1.status == :queued))

    metadata = BrusselsWtf.PDF.Processor.metadata()
    assert retry_run.processor_name == metadata.native_processor_name
    assert retry_run.processor_version == metadata.native_processor_version
    assert retry_run.config_hash == metadata.config_hash

    detail = get(recycle(acted), ~p"/review/cases/#{context.review_case.id}")
    document = detail |> html_response(200) |> LazyHTML.from_document()

    [csrf] =
      LazyHTML.attribute(document["form[action$='/notes'] input[name='_csrf_token']"], "value")

    noted =
      detail
      |> recycle()
      |> post(~p"/review/cases/#{context.review_case.id}/notes", %{
        "_csrf_token" => csrf,
        "body" => "Compared against page one."
      })

    assert redirected_to(noted) == ~p"/review/cases/#{context.review_case.id}"
    reviewed = Review.get_review_case!(context.review_case.id, actor: actor)
    assert [%{actor_id: "rico", body: "Compared against page one."}] = reviewed.notes
  end

  test "an authenticated dossier action resolves the case and renders its audit", %{
    conn: conn,
    actor: actor,
    context: context
  } do
    meeting =
      BrusselsWtf.Council.upsert_meeting!(%{
        commune_id: context.commune.id,
        municipal_identifier: "dossier-review",
        scheduled_on: ~D[2026-08-20]
      })

    item =
      BrusselsWtf.Council.upsert_rendered_agenda_item!(%{
        council_meeting_id: meeting.id,
        item_number: "1",
        stable_anchor: "dossier-review-1",
        source_wording: "Dossier review fixture",
        procedural_state: :proposal
      })

    dossier =
      BrusselsWtf.Council.upsert_dossier!(%{slug: "review-dossier", title: "Review dossier"})

    link =
      BrusselsWtf.Council.upsert_dossier_link!(%{
        agenda_item_id: item.id,
        dossier_id: dossier.id,
        match_method: :automated,
        confidence: 0.90,
        matcher_name: "review-fixture",
        matcher_version: "1",
        processing_generation: "review-fixture",
        disposition: :unreviewed
      })

    review_case =
      Review.open_review_case!(%{
        kind: :link_correction,
        commune_id: context.commune.id,
        affected_record_id: link.id,
        affected_record_type: "dossier_link",
        processing_generation: "link-review",
        summary: "Review dossier link",
        normalized_content: %{
          "dossier_link_id" => link.id,
          "dossier_id" => dossier.id,
          "agenda_item_id" => item.id
        }
      })

    detail = get(conn, ~p"/review/cases/#{review_case.id}")
    document = detail |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.attribute(document["form[action$='/actions/retry']"], "action") == []

    [csrf] =
      LazyHTML.attribute(
        document["form[action$='/actions/confirm-dossier-link'] input[name='_csrf_token']"],
        "value"
      )

    acted =
      detail
      |> recycle()
      |> post(~p"/review/cases/#{review_case.id}/actions/confirm-dossier-link", %{
        "_csrf_token" => csrf,
        "note" => "Identifier confirmed",
        "dossier_link_id" => link.id
      })

    assert redirected_to(acted) == ~p"/review/cases/#{review_case.id}"
    assert BrusselsWtf.Council.get_dossier_link!(link.id).disposition == :confirmed
    assert Review.get_review_case!(review_case.id, actor: actor).status == :resolved

    body = acted |> recycle() |> get(~p"/review/cases/#{review_case.id}") |> html_response(200)
    assert body =~ "Confirm link by rico"
    assert body =~ "Identifier confirmed"
  end

  defp build_context! do
    now = BrusselsWtf.Clock.utc_now()

    commune =
      Ingestion.create_commune!(%{
        slug: "ixelles",
        name: "Ixelles",
        index_url: "https://example.test/index"
      })

    url = "https://example.test/agenda.pdf"
    bytes = "%PDF immutable source"
    {:ok, archived} = BrusselsWtf.Archive.store(bytes)

    locator =
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: url,
        parent_index_url: commune.index_url,
        meeting_identifier: "268",
        role: :agenda,
        language: :fr,
        observed_label: "Agenda",
        discovered_at: now
      })

    poll =
      Ingestion.start_poll_run!(%{
        commune_id: commune.id,
        started_at: now,
        kind: :poll_now,
        requester_id: "test-harness",
        target_type: :locator,
        target_id: locator.id,
        check_key: "review-fixture:#{Ecto.UUID.generate()}"
      })

    record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: url,
        role: :agenda,
        original_language: :fr
      })

    version =
      Ingestion.upsert_source_version!(%{
        source_record_id: record.id,
        sha256: archived.sha256,
        byte_size: byte_size(bytes),
        media_type: "application/pdf",
        object_key: archived.object_key,
        first_retrieved_at: now
      })

    Ingestion.record_observation!(%{
      source_locator_id: locator.id,
      source_version_id: version.id,
      poll_run_id: poll.id,
      check_key: "review-fixture",
      observed_at: now,
      status: :success,
      http_status: 200,
      sha256: archived.sha256,
      final_url: "https://redirected.example.test/agenda.pdf",
      response_headers: %{"etag" => ["fixture"]},
      redirect_chain: [%{"status" => 302, "url" => url}]
    })

    run =
      Ingestion.record_processing_run!(%{
        source_version_id: version.id,
        processor_name: "native-extraction",
        processor_version: "1",
        config_hash: "fixture",
        status: :failed,
        failure_classification: "invalid_content",
        tool_versions: %{"pdfinfo" => "fixture-poppler"},
        diagnostics: %{"kind" => "invalid_pdf", "detail" => "syntax"},
        quality_measurements: %{"accepted" => false, "rejected_pages" => [1]},
        started_at: now,
        completed_at: now,
        duration_ms: 17,
        output: %{
          "text" => "broken extraction",
          "quality" => %{"text_ratio" => 0.12},
          "diagnostic" => "too little text"
        }
      })

    Ingestion.record_processing_attempt!(%{
      processing_run_id: run.id,
      attempt: 1,
      status: :failed,
      started_at: now,
      completed_at: now,
      duration_ms: 17,
      failure_classification: "invalid_content",
      diagnostics: %{"kind" => "invalid_pdf", "detail" => "syntax"},
      tool_versions: %{"pdfinfo" => "fixture-poppler"},
      quality_measurements: %{"accepted" => false, "rejected_pages" => [1]}
    })

    derived_bytes = "broken extraction artifact"
    {:ok, derived_archive} = BrusselsWtf.Archive.store(derived_bytes)

    artifact =
      Ingestion.upsert_derived_artifact!(%{
        source_version_id: version.id,
        processing_run_id: run.id,
        input_sha256: version.sha256,
        output_sha256: derived_archive.sha256,
        processor_name: run.processor_name,
        processor_version: run.processor_version,
        config_hash: run.config_hash,
        output_kind: "extracted-text",
        object_key: derived_archive.object_key,
        media_type: "text/plain",
        byte_size: byte_size(derived_bytes),
        quality_measurements: %{"text_ratio" => 0.12}
      })

    Ingestion.link_processing_run_artifact!(%{
      processing_run_id: run.id,
      derived_artifact_id: artifact.id,
      role: :native_output
    })

    review_case =
      Review.open_review_case!(%{
        kind: :extraction,
        commune_id: commune.id,
        affected_record_id: record.id,
        affected_record_type: "source_record",
        source_record_id: record.id,
        source_version_id: version.id,
        processing_generation: "gen-1",
        urgency: :high,
        summary: "Native extraction quality failed",
        extracted_text: "broken extraction",
        normalized_content: %{"title" => "Candidate title"},
        quality_measurements: %{"text_ratio" => 0.12},
        diagnostics: %{"error" => "too little text"},
        related_evidence: %{"location" => "page 1"}
      })

    %{
      commune: commune,
      locator: locator,
      record: record,
      version: version,
      review_case: review_case,
      url: url,
      bytes: bytes,
      artifact: artifact,
      derived_bytes: derived_bytes
    }
  end
end
