defmodule BrusselsWtf.Corpus.CurrentAcceptanceTest do
  use BrusselsWtfWeb.ConnCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.{Archive, Council, HTTP, Ingestion}
  alias BrusselsWtf.Corpus.Manifest
  alias BrusselsWtf.Review.Actor

  # Full official PDFs remain private pending source-specific rights/privacy disposition.
  # Run explicitly with CURRENT_CORPUS_SOURCE_DIR and --include external. Fixtures must
  # match all four release-owned raw hashes; this test never fetches from the network.
  @moduletag :external

  setup do
    config_keys = [:processors, :pdf_processor, :coverage_processor, :coverage_generation]
    previous = Map.new(config_keys, &{&1, Application.fetch_env!(:brussels_wtf, &1)})
    previous_time = BrusselsWtf.Clock.utc_now()

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:brussels_wtf, key, value) end)
      BrusselsWtf.Clock.Controlled.set(previous_time)
    end)

    Application.put_env(:brussels_wtf, :processors, BrusselsWtf.Processors.RecordedCorpus)
    Application.put_env(:brussels_wtf, :pdf_processor, BrusselsWtf.PDF.PopplerOcr)

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

    HTTP.Stub.reset()
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-09-11 12:00:00Z])
    {:ok, fixture_dir: System.fetch_env!("CURRENT_CORPUS_SOURCE_DIR")}
  end

  test "ordinary retained-source processing publishes exactly eight current proposals in three locales",
       %{conn: conn, fixture_dir: fixture_dir} do
    contract = Manifest.load!("current-20260911")
    actor = %Actor{id: "rico", role: :reviewer}

    imported = Enum.map(contract["meetings"], &acquire_and_normalize!(&1, fixture_dir))
    assert length(imported) == 4
    meeting_ids = Enum.map(imported, & &1.meeting.id)

    scopes =
      Map.new(
        imported,
        &{&1.meeting.id, Enum.map(&1.contract["items"], fn item -> item["key"] end)}
      )

    batch = Council.request_coverage_batch!(meeting_ids, actor: actor, item_scopes: scopes)
    assert batch.item_scopes == scopes
    assert is_nil(batch.content_reviewed_by)
    assert is_nil(batch.content_review_manifest_sha256)
    assert Council.list_corpus_import_batches!() == []

    for meeting_id <- meeting_ids do
      assert :ok =
               perform_job(BrusselsWtf.Workers.PublishMeeting, %{
                 meeting_id: meeting_id,
                 generation_kind: "backfill",
                 coverage_batch_id: batch.id
               })
    end

    pages =
      Enum.map(meeting_ids, fn id ->
        id |> Council.get_meeting!() |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
      end)
      |> Ash.load!([
        :current_revision,
        :coverage_runs,
        :locale_variants,
        council_meeting: [:commune, agenda_items: [:coverage_variants, :proposals, :decisions]]
      ])

    assert Enum.all?(pages, &(&1.publication_status == :published))

    items =
      pages |> Enum.flat_map(& &1.council_meeting.agenda_items) |> Enum.filter(& &1.published?)

    assert length(items) == 8
    assert length(Enum.uniq_by(items, &{&1.council_meeting_id, &1.stable_anchor})) == 8

    assert Enum.all?(
             items,
             &(&1.procedural_state == :proposal and &1.outcome == :unknown and &1.decisions == [])
           )

    runs = Enum.flat_map(pages, & &1.coverage_runs)
    assert length(runs) == 12

    expected_config =
      {Manifest.digest(), Manifest.digest("current-20260911")}
      |> :erlang.term_to_binary([:deterministic])
      |> BrusselsWtf.Digest.sha256()

    assert Enum.all?(runs, &(&1.config_hash == "sha256:" <> expected_config))
    assert Enum.all?(runs, &(&1.status == :succeeded and &1.usage["network_calls"] == 0))
    assert Enum.all?(runs, &(:human_reviewed not in &1.carried_provenance))

    for page <- pages do
      assert is_nil(page.current_revision.actor_id)
      assert is_nil(page.current_revision.publication_metadata["content_review"])
      assert Enum.sort(Enum.map(page.locale_variants, & &1.locale)) == ~w(en fr nl)

      assert BrusselsWtf.Council.PublicationGate.evaluate(
               page.id,
               page.current_revision.publication_input_hash
             ).ready?
    end

    for item <- items, variant <- item.coverage_variants do
      assert :ai_generated in variant.provenance
      refute :human_reviewed in variant.provenance
      if variant.locale != "fr", do: assert(:machine_translated in variant.provenance)
    end

    for imported_meeting <- imported, locale <- ~w(fr nl en) do
      meeting = imported_meeting.contract

      html =
        conn
        |> recycle()
        |> get(
          "/meetings/#{meeting["commune"]}/#{meeting["municipal_identifier"]}?lang=#{locale}"
        )
        |> html_response(200)

      document = LazyHTML.from_document(html)
      public_text = LazyHTML.text(document)

      for selected_item <- meeting["items"] do
        item = Enum.find(items, &(&1.authoritative_identifier == selected_item["key"]))
        assert html =~ ~s(id="#{item.stable_anchor}")
        assert public_text =~ selected_item["coverage"][locale]["title"]
      end
    end

    for imported_meeting <- imported do
      %{version: version, run: run, contract: meeting} = imported_meeting

      assert :ok =
               Ingestion.Pipeline.normalize(
                 run.id,
                 hd(meeting["sources"])["url"],
                 1,
                 3,
                 :backfill
               )

      assert Ingestion.get_source_version!(version.id).sha256 == version.sha256
      reloaded = Council.get_meeting!(imported_meeting.meeting.id) |> Ash.load!(:agenda_items)

      assert MapSet.new(reloaded.agenda_items, & &1.id) ==
               MapSet.new(imported_meeting.meeting.agenda_items, & &1.id)

      assert length(HTTP.Stub.requests(hd(meeting["sources"])["url"])) == 1
    end

    assert length(Council.list_coverage_batches!()) == 1
  end

  test "changed current bytes stay archived but cannot replace the supported interpretation", %{
    fixture_dir: fixture_dir
  } do
    meeting_contract = Manifest.meeting!("ixelles-269")
    imported = acquire_and_normalize!(meeting_contract, fixture_dir)
    [source] = meeting_contract["sources"]

    changed =
      File.read!(Path.join(fixture_dir, source["name"] <> ".pdf")) <> "\n% changed source bytes\n"

    assert BrusselsWtf.Digest.sha256(changed) != source["sha256"]
    [locator] = Ingestion.list_document_locators!(imported.meeting.commune_id)
    now = ~U[2026-09-11 12:01:00Z]
    BrusselsWtf.Clock.Controlled.set(now)
    key = "changed-current:#{locator.id}"

    poll_run =
      Ingestion.start_poll_run!(%{
        commune_id: locator.commune_id,
        started_at: now,
        kind: :backfill,
        requester_id: "rico",
        target_type: :locator,
        target_id: locator.id,
        check_key: key,
        scope: :backfill,
        status: :running
      })

    HTTP.Stub.put(source["url"], %{
      body: changed,
      headers: %{"content-type" => ["application/pdf"]}
    })

    assert :ok = Ingestion.Pipeline.retrieve(locator.id, poll_run.id, key)

    observation =
      locator
      |> Ash.load!(:observations)
      |> Map.fetch!(:observations)
      |> Enum.find(&(&1.check_key == key))

    changed_version = Ingestion.get_source_version!(observation.source_version_id)
    refute changed_version.id == imported.version.id
    assert {:ok, ^changed} = Archive.get(changed_version.object_key)
    assert :ok = Ingestion.Pipeline.extract(changed_version.id, 1, :backfill)

    run =
      changed_version
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.find(&(&1.processor_role == :native_extraction and &1.status == :succeeded))

    assert run.quality_measurements["accepted"]
    assert :ok = Ingestion.Pipeline.normalize(run.id, source["url"], 1, 3, :backfill)

    reloaded = Council.get_meeting!(imported.meeting.id) |> Ash.load!(:agenda_items)

    assert MapSet.new(reloaded.agenda_items, & &1.id) ==
             MapSet.new(imported.meeting.agenda_items, & &1.id)

    assert Enum.all?(
             reloaded.agenda_items,
             &(&1.current_source_version_id == imported.version.id and &1.outcome == :unknown)
           )

    assert [review_case] =
             BrusselsWtf.Review.list_review_cases!(%{},
               actor: %Actor{id: "rico", role: :reviewer}
             )

    assert review_case.kind == :normalization
    assert review_case.source_version_id == changed_version.id
    assert review_case.diagnostics["classification"] == "processor_unavailable"
    assert Council.list_coverage_batches!() == []
    refute_enqueued worker: BrusselsWtf.Workers.PublishMeeting
  end

  defp acquire_and_normalize!(meeting_contract, fixture_dir) do
    [source] = meeting_contract["sources"]
    bytes = File.read!(Path.join(fixture_dir, source["name"] <> ".pdf"))
    assert BrusselsWtf.Digest.sha256(bytes) == source["sha256"]
    assert byte_size(bytes) == source["byte_size"]
    config = BrusselsWtf.Communes.configuration!(meeting_contract["commune"])

    commune =
      Ingestion.create_commune!(%{
        slug: meeting_contract["commune"],
        name: config.name,
        index_url: source["parent_index_url"]
      })

    scheduled_on = Date.from_iso8601!(meeting_contract["scheduled_on"])

    meeting =
      Council.upsert_meeting!(%{
        commune_id: commune.id,
        municipal_identifier: meeting_contract["municipal_identifier"],
        scheduled_on: scheduled_on
      })

    now = BrusselsWtf.Clock.utc_now()

    locator =
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: source["url"],
        parent_index_url: source["parent_index_url"],
        meeting_identifier: meeting_contract["municipal_identifier"],
        scheduled_on: scheduled_on,
        role: String.to_existing_atom(source["role"]),
        language: String.to_existing_atom(source["language"]),
        observed_label: source["name"],
        discovered_at: now
      })

    key = "current-acceptance:#{locator.id}"

    poll_run =
      Ingestion.start_poll_run!(%{
        commune_id: commune.id,
        started_at: now,
        kind: :backfill,
        requester_id: "rico",
        target_type: :locator,
        target_id: locator.id,
        check_key: key,
        scope: :backfill,
        status: :running
      })

    HTTP.Stub.put(source["url"], %{body: bytes, headers: %{"content-type" => ["application/pdf"]}})

    assert :ok = Ingestion.Pipeline.retrieve(locator.id, poll_run.id, key)
    Ingestion.complete_poll_run!(poll_run, %{completed_at: now})
    [observation] = locator |> Ash.load!(:observations) |> Map.fetch!(:observations)
    assert observation.http_status == 200
    assert observation.final_url == source["url"]
    assert observation.response_headers == %{"content-type" => ["application/pdf"]}
    assert observation.sha256 == source["sha256"]
    version = Ingestion.get_source_version!(observation.source_version_id)
    assert DateTime.compare(version.first_retrieved_at, now) == :eq
    assert {:ok, ^bytes} = Archive.get(version.object_key)
    assert :ok = Ingestion.Pipeline.extract(version.id, 1, :backfill)

    run =
      version
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.find(&(&1.processor_role == :native_extraction and &1.status == :succeeded))

    assert run.quality_measurements["accepted"]
    assert run.output["page_count"] == source["page_count"]
    assert :ok = Ingestion.Pipeline.normalize(run.id, source["url"], 1, 3, :backfill)
    meeting = Council.get_meeting!(meeting.id) |> Ash.load!([:agenda_items, :commune])
    assert length(meeting.agenda_items) == 2
    assert Enum.all?(meeting.agenda_items, &(&1.outcome == :unknown))

    assert BrusselsWtfWeb.MeetingTime.group(:proposal, meeting.scheduled_on) ==
             if(meeting.commune.slug == "ixelles", do: :coming, else: :awaiting)

    %{version: version, run: run, meeting: meeting, contract: meeting_contract}
  end
end
