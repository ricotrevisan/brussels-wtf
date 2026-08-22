defmodule BrusselsWtf.Corpus.AcceptanceTest do
  use BrusselsWtfWeb.ConnCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.{Council, Ingestion}
  alias BrusselsWtf.Corpus.{Import, Manifest}
  alias BrusselsWtf.Review.Actor

  setup do
    previous_processors = Application.fetch_env!(:brussels_wtf, :processors)
    previous_coverage = Application.fetch_env!(:brussels_wtf, :coverage_processor)
    previous_generation = Application.fetch_env!(:brussels_wtf, :coverage_generation)
    previous_time = BrusselsWtf.Clock.utc_now()

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :processors, previous_processors)
      Application.put_env(:brussels_wtf, :coverage_processor, previous_coverage)
      Application.put_env(:brussels_wtf, :coverage_generation, previous_generation)
      BrusselsWtf.Clock.Controlled.set(previous_time)
    end)

    Application.put_env(:brussels_wtf, :processors, BrusselsWtf.Test.CorpusProcessor)

    Application.put_env(
      :brussels_wtf,
      :coverage_processor,
      BrusselsWtf.Processors.RecordedCorpusCoverage
    )

    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :recorded,
      backfill_enabled: true,
      backfill_max_batch_size: 8,
      monthly_budget_cents: nil
    })

    BrusselsWtf.Processors.Stub.reset()
    BrusselsWtf.HTTP.Stub.reset()
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-08-21 14:30:00Z])
    :ok
  end

  test "the sealed release corpus publishes eight real meetings, 24 anchored items and one verified dossier",
       %{
         conn: conn
       } do
    contract = Manifest.load!()
    actor = %Actor{id: "rico", role: :reviewer}

    for meeting <- contract["meetings"], source <- meeting["sources"] do
      text = contract_text(meeting, source)

      BrusselsWtf.Processors.Stub.put(source["sha256"], %{
        extract: %{"text" => text, "page_texts" => [text]}
      })
    end

    keys = Enum.map(contract["meetings"], & &1["key"])
    batch = Import.request!(keys, actor)

    for meeting <- contract["meetings"], source <- meeting["sources"] do
      assert :ok = Import.import_source(batch.id, meeting["key"], source["name"])
    end

    imported = Council.get_corpus_import_batch!(batch.id)
    assert length(imported.source_version_ids) == 9
    assert length(imported.meeting_ids) == 8

    for version_id <- imported.source_version_ids do
      version = version_id |> Ingestion.get_source_version!() |> Ash.load!(:source_record)
      assert :ok = Ingestion.Pipeline.extract(version.id, 1, :backfill)

      run =
        version.id
        |> Ingestion.get_source_version!()
        |> Ash.load!(:processing_runs)
        |> Map.fetch!(:processing_runs)
        |> Enum.find(&(&1.status == :succeeded and &1.processor_role == :native_extraction))

      assert :ok =
               Ingestion.Pipeline.normalize(
                 run.id,
                 version.source_record.origin_url,
                 1,
                 3,
                 :backfill
               )
    end

    ixelles_268 =
      imported.meeting_ids
      |> Enum.map(&(Council.get_meeting!(&1) |> Ash.load!(:commune)))
      |> Enum.find(&(&1.commune.slug == "ixelles" and &1.municipal_identifier == "268"))

    ixelles_source_version =
      imported.source_version_ids
      |> Enum.map(&(Ingestion.get_source_version!(&1) |> Ash.load!(:source_record)))
      |> Enum.find(&(&1.source_record.council_meeting_id == ixelles_268.id))

    extra_real_item =
      Council.upsert_agenda_item!(%{
        council_meeting_id: ixelles_268.id,
        item_number: "4",
        authoritative_identifier: "4",
        source_wording: "Previously published real item outside the sealed corpus selection",
        current_source_version_id: ixelles_source_version.id,
        current_version_order: "preexisting",
        procedural_state: :unknown,
        outcome: :unknown
      })

    Council.publish_agenda_item_state!(extra_real_item)
    assert Council.get_agenda_item!(extra_real_item.id).published?

    ready = Import.refresh!(batch.id, actor)
    assert ready.status == :ready_for_coverage
    assert ready.metrics["documents_downloaded"] == 9
    assert ready.metrics["normalized_items"] == 24
    assert ready.metrics["generation_calls"] == 0
    assert ready.metrics["generation_usage"]["network_calls"] == 0

    prepared = Import.prepare_coverage!(batch.id, actor)
    assert prepared.coverage_batch_id
    assert prepared.dossier_id
    assert length(prepared.dossier_link_ids) == 2
    assert prepared.content_reviewed_by == "rico"
    assert DateTime.compare(prepared.content_reviewed_at, ~U[2026-08-21 14:30:00Z]) == :eq

    coverage_batch = Council.get_coverage_batch!(prepared.coverage_batch_id)
    assert map_size(coverage_batch.item_scopes) == 8
    assert Enum.all?(coverage_batch.item_scopes, fn {_meeting_id, keys} -> length(keys) == 3 end)
    assert coverage_batch.content_reviewed_by == "rico"
    assert coverage_batch.content_reviewed_at == prepared.content_reviewed_at
    assert coverage_batch.content_review_manifest_sha256 == Manifest.digest()

    prepared_again = Import.prepare_coverage!(batch.id, actor)
    assert prepared_again.coverage_batch_id == prepared.coverage_batch_id
    assert prepared_again.dossier_id == prepared.dossier_id
    assert prepared_again.dossier_link_ids == prepared.dossier_link_ids
    assert length(Council.list_coverage_batches!()) == 1

    dossier_actions =
      BrusselsWtf.Council.DossierAction
      |> Ash.read!(domain: Council, actor: actor)

    assert length(dossier_actions) == 2

    for meeting_id <- prepared.meeting_ids do
      assert :ok =
               perform_job(BrusselsWtf.Workers.PublishMeeting, %{
                 meeting_id: meeting_id,
                 generation_kind: "backfill",
                 coverage_batch_id: prepared.coverage_batch_id
               })
    end

    completed = Import.refresh!(batch.id, actor)
    assert completed.status == :completed
    assert completed.metrics["pages_published"] == 8
    assert completed.metrics["generation_calls"] == 24
    assert completed.metrics["generation_usage"]["network_calls"] == 0
    assert completed.metrics["generation_usage"]["cost_cents"] == 0
    assert length(completed.meeting_page_ids) == 8
    assert length(completed.coverage_run_ids) == 24
    assert completed.review_case_ids == []

    pages =
      completed.meeting_page_ids
      |> Enum.map(&Council.get_meeting_page!/1)
      |> Ash.load!([
        :locale_variants,
        :current_revision,
        :coverage_runs,
        council_meeting: [
          :commune,
          agenda_items: [:coverage_variants, proposals: [:evidence], decisions: [:evidence]]
        ]
      ])

    assert length(pages) == 8

    assert Enum.all?(pages, fn page ->
             page.current_revision.actor_id == "rico" and
               page.current_revision.publication_metadata["content_review"] == %{
                 "actor_id" => "rico",
                 "reviewed_at" => "2026-08-21T14:30:00.000000Z",
                 "manifest_sha256" => Manifest.digest()
               } and
               Enum.all?(page.coverage_runs, &(:human_reviewed in &1.carried_provenance))
           end)

    all_items =
      pages
      |> Enum.flat_map(& &1.council_meeting.agenda_items)
      |> Enum.uniq_by(& &1.id)

    items = Enum.filter(all_items, & &1.published?)
    refute Enum.find(all_items, &(&1.id == extra_real_item.id)).published?
    assert length(items) == 24
    assert Enum.all?(items, &(&1.stable_anchor =~ ~r/^agenda-item-/))
    assert length(Enum.uniq_by(items, & &1.stable_anchor)) == 24

    assert Enum.all?(items, fn item ->
             Enum.all?(item.proposals, fn proposal ->
               not proposal.synthetic and Enum.all?(proposal.evidence, &(not &1.synthetic))
             end) and
               Enum.all?(item.decisions, fn decision ->
                 Enum.all?(decision.evidence, &(not &1.synthetic))
               end)
           end)

    assert Enum.all?(items, fn item ->
             Enum.all?(item.coverage_variants, fn variant ->
               :human_reviewed in variant.provenance and :ai_generated in variant.provenance and
                 (variant.locale == "fr" or :machine_translated in variant.provenance)
             end)
           end)

    ixelles_page =
      Enum.find(
        pages,
        &(&1.council_meeting.commune.slug == "ixelles" and
            &1.council_meeting.municipal_identifier == "268")
      )

    bundles =
      Map.new(~w(fr nl en), fn locale ->
        {locale, bundle_from_content(ixelles_page.current_revision.content, locale)}
      end)

    Council.PublicationLifecycle.factual_correction!(
      ixelles_page.id,
      bundles,
      %{"fr" => "Vérification", "nl" => "Controle", "en" => "Verification"},
      actor
    )

    Council.PublicationLifecycle.typography_correction!(
      ixelles_page.id,
      "en",
      bundles["en"],
      actor
    )

    Council.PublicationLifecycle.withdraw!(
      ixelles_page.id,
      %{"fr" => "Test", "nl" => "Test", "en" => "Test"},
      actor
    )

    Council.PublicationLifecycle.republish!(ixelles_page.id, actor)

    reloaded_ixelles_page =
      ixelles_page.id |> Council.get_meeting_page!() |> Ash.load!(:current_revision)

    assert MapSet.new(Map.keys(reloaded_ixelles_page.current_revision.content["items"])) ==
             MapSet.new(~w(1 10 13))

    assert MapSet.new(Enum.map(pages, & &1.council_meeting.commune.slug)) ==
             MapSet.new(~w(ixelles uccle forest city-of-brussels))

    timeline = conn |> recycle() |> get("/?lang=en") |> html_response(200)
    timeline_document = LazyHTML.from_document(timeline)
    timeline_entries = timeline_document["article[data-commune]"]

    assert Enum.count(timeline_entries) == 24

    assert MapSet.new(LazyHTML.attribute(timeline_entries, "data-commune")) ==
             MapSet.new(~w(ixelles uccle forest city-of-brussels))

    refute timeline =~ "demo-"
    refute timeline =~ "Demonstration reference"

    for meeting <- contract["meetings"], locale <- ~w(fr nl en) do
      html =
        conn
        |> recycle()
        |> get(
          "/meetings/#{meeting["commune"]}/#{meeting["municipal_identifier"]}?lang=#{locale}"
        )
        |> html_response(200)

      for item <- meeting["items"] do
        page_item = Enum.find(items, &(&1.authoritative_identifier == item["key"]))
        assert html =~ ~s(id="#{page_item.stable_anchor}")
      end
    end

    dossier_html =
      conn
      |> recycle()
      |> get("/dossiers/city-opp-2026-185-fritkot-socles?lang=en")
      |> html_response(200)

    assert dossier_html =~ "Bases for Fritkot modules — OPP/2026/185"
    assert dossier_html =~ "2026-06-08"
    assert dossier_html =~ "2026-06-29"
    assert dossier_html =~ "OPP/2026/185"

    for meeting <- contract["meetings"], source <- meeting["sources"] do
      assert BrusselsWtf.HTTP.Stub.requests(source["url"]) == []
    end

    assert_raise Ash.Error.Invalid, ~r/completed real-corpus batches are closed/, fn ->
      Ash.update!(completed, %{failure: "late_failure"}, action: :block, domain: Council)
    end
  end

  defp bundle_from_content(content, locale) do
    %{
      "page" => content["page"][locale],
      "items" =>
        Map.new(content["items"], fn {item_key, item} ->
          {item_key, %{"claim_refs" => item["claim_refs"], "variant" => item["variants"][locale]}}
        end)
    }
  end

  defp contract_text(meeting, source) do
    evidence =
      meeting["items"]
      |> Enum.filter(&(&1["source"] == source["name"]))
      |> Enum.map(fn item ->
        if item["state"] == "proposal",
          do: item["proposal"]["excerpt"],
          else: item["decision"]["excerpt"]
      end)

    Enum.join(source["markers"] ++ evidence, "\n")
  end
end
