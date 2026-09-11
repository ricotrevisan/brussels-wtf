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

      legacy =
        if version.sha256 == hd(Manifest.meeting!("uccle-2025-06-26")["sources"])["sha256"] do
          meeting =
            Council.upsert_meeting!(%{
              commune_id: version.source_record.commune_id,
              municipal_identifier: "2025-06-26",
              scheduled_on: ~D[2025-06-26]
            })

          item =
            Council.upsert_agenda_item!(%{
              council_meeting_id: meeting.id,
              item_number: "5",
              authoritative_identifier: "26.06.2025/A/0005",
              source_wording: "Legacy camera interpretation",
              current_version_order: "0:legacy",
              current_source_version_id: version.id
            })

          Council.record_decision!(%{
            agenda_item_id: item.id,
            source_version_id: version.id,
            disposition: :approved,
            statement: "Le Conseil approuve le point."
          })
        end

      assert :ok =
               Ingestion.Pipeline.normalize(
                 run.id,
                 version.source_record.origin_url,
                 1,
                 3,
                 :backfill
               )

      if legacy do
        assert Council.get_decision!(legacy.id).statement == "Le Conseil approuve le point."
        item = Council.get_agenda_item!(legacy.agenda_item_id)
        refute item.current_decision_id == legacy.id
        assert Council.get_decision!(item.current_decision_id).statement =~ "trois ans"
      end
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
    assert is_nil(prepared.content_reviewed_by)
    assert is_nil(prepared.content_reviewed_at)

    coverage_batch = Council.get_coverage_batch!(prepared.coverage_batch_id)
    assert map_size(coverage_batch.item_scopes) == 8
    assert Enum.all?(coverage_batch.item_scopes, fn {_meeting_id, keys} -> length(keys) == 3 end)
    assert is_nil(coverage_batch.content_reviewed_by)
    assert is_nil(coverage_batch.content_reviewed_at)
    assert is_nil(coverage_batch.content_review_manifest_sha256)

    prepared_again = Import.prepare_coverage!(batch.id, actor)
    assert prepared_again.coverage_batch_id == prepared.coverage_batch_id
    assert prepared_again.dossier_id == prepared.dossier_id
    assert prepared_again.dossier_link_ids == prepared.dossier_link_ids
    assert length(Council.list_coverage_batches!()) == 1

    dossier_actions =
      BrusselsWtf.Council.DossierAction
      |> Ash.read!(domain: Council, actor: actor)

    assert length(dossier_actions) == 2
    assert Enum.all?(dossier_actions, &(&1.action == :confirm_link and &1.actor_id == "rico"))
    assert MapSet.new(dossier_actions, & &1.subject_id) == MapSet.new(prepared.dossier_link_ids)

    assert Enum.all?(dossier_actions, fn action ->
             action.details["corpus_import_batch_id"] == prepared.id and
               action.details["manifest_sha256"] == Manifest.digest()
           end)

    for meeting_id <- prepared.meeting_ids do
      assert :ok =
               perform_job(BrusselsWtf.Workers.PublishMeeting, %{
                 meeting_id: meeting_id,
                 generation_kind: "backfill",
                 coverage_batch_id: prepared.coverage_batch_id
               })
    end

    # Production already has failed and superseded generation attempts. They remain
    # auditable, but cannot count as runs supporting the current eight revisions.
    page_id =
      hd(prepared.meeting_ids)
      |> Council.get_meeting!()
      |> Ash.load!(:meeting_page)
      |> Map.fetch!(:meeting_page)
      |> Map.fetch!(:id)

    historical = Council.list_coverage_runs!(page_id) |> hd()

    attrs =
      Map.take(historical, [
        :meeting_page_id,
        :operation,
        :locale,
        :input_hash,
        :output_hash,
        :processor_name,
        :processor_version,
        :config_hash,
        :provider_category,
        :model,
        :method,
        :input,
        :output
      ])

    old_failure =
      Council.record_coverage_run!(
        Map.merge(attrs, %{
          status: :failed,
          failure_details: %{"classification" => "previous_attempt"}
        })
      )

    completed = Import.refresh!(batch.id, actor)
    assert completed.status == :completed
    assert completed.metrics["pages_published"] == 8
    assert completed.metrics["generation_calls"] == 24
    assert completed.metrics["generation_usage"]["network_calls"] == 0
    assert completed.metrics["generation_usage"]["cost_cents"] == 0
    assert length(completed.meeting_page_ids) == 8
    assert length(completed.coverage_run_ids) == 24
    refute old_failure.id in completed.coverage_run_ids
    assert completed.metrics["generation_runs_all_revisions"] == 25
    assert Ash.get!(BrusselsWtf.Council.CoverageRun, old_failure.id).status == :failed
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
             is_nil(page.current_revision.actor_id) and
               is_nil(page.current_revision.publication_metadata["content_review"]) and
               Enum.all?(page.coverage_runs, &(:human_reviewed not in &1.carried_provenance))
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
               :human_reviewed not in variant.provenance and :ai_generated in variant.provenance and
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

    # Official Forest minutes, 24 March 2026, pp. 30–31 and 45–46:
    # the adopted operative act is acknowledgement of executive decisions, not
    # approval of the underlying contracts. Item 20 is a real budget approval.
    for {locale, other, approved, acknowledgement} <- [
          {"fr", "autre", "approuvée", "Le conseil prend connaissance"},
          {"nl", "andere", "goedgekeurd", "De raad neemt kennis"},
          {"en", "other", "approved", "The council took note"}
        ] do
      document =
        conn
        |> recycle()
        |> get("/meetings/forest/2026-03-24?lang=#{locale}")
        |> html_response(200)
        |> LazyHTML.from_document()

      for number <- ["9", "15"] do
        item = Enum.find(items, &(&1.authoritative_identifier == "forest-2026-03-24-#{number}"))
        article = document["article##{item.stable_anchor}"]
        assert item.outcome == :other
        assert LazyHTML.text(article["h3"]) =~ other
        refute LazyHTML.text(article["h3"]) =~ approved
        assert LazyHTML.text(article) =~ acknowledgement
      end

      budget_item = Enum.find(items, &(&1.authoritative_identifier == "forest-2026-03-24-20"))
      assert budget_item.outcome == :approved
      assert LazyHTML.text(document["article##{budget_item.stable_anchor} h3"]) =~ approved
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

    dossier_document = LazyHTML.from_document(dossier_html)
    dossier_hrefs = LazyHTML.attribute(dossier_document["ol li h2 a"], "href")
    assert length(dossier_hrefs) == 2

    for page <- Enum.filter(pages, &(&1.council_meeting.commune.slug == "city-of-brussels")) do
      path =
        "/meetings/city-of-brussels/#{page.council_meeting.municipal_identifier}?lang=en"

      anchors =
        for item <- page.council_meeting.agenda_items,
            item.published?,
            do: item.stable_anchor

      assert Enum.any?(dossier_hrefs, fn href ->
               String.starts_with?(href, path <> "#") and
                 String.trim_leading(href, path <> "#") in anchors
             end)
    end

    for meeting <- contract["meetings"], source <- meeting["sources"] do
      assert BrusselsWtf.HTTP.Stub.requests(source["url"]) == []
    end

    assert_raise Ash.Error.Invalid, ~r/completed real-corpus batches are closed/, fn ->
      Ash.update!(completed, %{failure: "late_failure"}, action: :block, domain: Council)
    end

    changed_en =
      put_in(
        bundles["en"],
        ["page", "summary"],
        "An earlier editorial summary requiring replacement."
      )

    Council.PublicationLifecycle.typography_correction!(ixelles_page.id, "en", changed_en, actor)

    replay = Import.request!(keys, actor)

    for meeting <- contract["meetings"], source <- meeting["sources"] do
      assert :ok = Import.import_source(replay.id, meeting["key"], source["name"])
    end

    assert Import.refresh!(replay.id, actor).status == :ready_for_coverage
    replay_prepared = Import.prepare_coverage!(replay.id, actor)
    assert replay_prepared.coverage_batch_id
    assert Import.refresh!(replay.id, actor).status == :ready_for_coverage

    for meeting_id <- replay_prepared.meeting_ids do
      assert :ok =
               perform_job(BrusselsWtf.Workers.PublishMeeting, %{
                 meeting_id: meeting_id,
                 generation_kind: "backfill",
                 coverage_batch_id: replay_prepared.coverage_batch_id
               })
    end

    assert Import.refresh!(replay.id, actor).status == :completed
  end

  for correction_kind <- [:editorial, :recorded] do
    @tag correction_kind: correction_kind
    test "a #{correction_kind} Forest correction replaces public dispositions atomically and preserves interpretations",
         %{conn: conn, correction_kind: correction_kind} do
      actor = %Actor{id: "rico", role: :reviewer}
      contract = Manifest.meeting!("forest-2026-03-24")
      [source] = contract["sources"]
      text = contract_text(contract, source)

      # Independently checked official PDF, not invented outcome fixtures. Both the
      # operative acknowledgement and the approval vote must survive normalization.
      assert source["sha256"] ==
               "6e31a35822196823ecba87cbd4b185ad7eb92e4c99cf6c86f441867a86086d26"

      BrusselsWtf.Processors.Stub.put(source["sha256"], %{
        extract: %{"text" => text, "page_texts" => [text]}
      })

      batch = Import.request!([contract["key"]], actor)
      assert :ok = Import.import_source(batch.id, contract["key"], "primary")
      [version_id] = Council.get_corpus_import_batch!(batch.id).source_version_ids
      assert :ok = Ingestion.Pipeline.extract(version_id, 1, :backfill)

      run =
        version_id
        |> Ingestion.get_source_version!()
        |> Ash.load!(:processing_runs)
        |> Map.fetch!(:processing_runs)
        |> Enum.find(&(&1.status == :succeeded and &1.processor_role == :native_extraction))

      assert :ok = Ingestion.Pipeline.normalize(run.id, source["url"], 1, 3, :backfill)
      meeting = Council.get_ingested_meeting!("forest", "2026-03-24")

      coverage_batch =
        Council.request_coverage_batch!([meeting.id],
          actor: actor,
          item_scopes: %{meeting.id => Enum.map(contract["items"], & &1["key"])}
        )

      assert :ok =
               perform_job(BrusselsWtf.Workers.PublishMeeting, %{
                 meeting_id: meeting.id,
                 generation_kind: "backfill",
                 coverage_batch_id: coverage_batch.id
               })

      page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
      [initial] = Council.list_publication_revisions!(page.id)
      bundles = Map.new(~w(fr nl en), &{&1, bundle_from_content(initial.content, &1)})

      # Recreate the earlier, overly broad public interpretation through domain
      # actions. It used the same real source and accurate acknowledgement summary.
      legacy_decisions =
        for number <- ["9", "15"] do
          item =
            Council.get_ingested_meeting!("forest", "2026-03-24").agenda_items
            |> Enum.find(&(&1.item_number == number))
            |> Ash.load!(decision: :evidence)

          assert item.decision.disposition == :other
          [evidence] = item.decision.evidence
          assert evidence.excerpt =~ "De prendre connaissance"
          assert evidence.excerpt =~ "Le Conseil approuve le projet de délibération."
          assert evidence.excerpt =~ "32 votants : 32 votes positifs."

          if number == "15",
            do: assert(evidence.excerpt =~ "sous réserve de l’approbation de la Tutelle")

          legacy =
            Council.record_decision!(%{
              agenda_item_id: item.id,
              source_version_id: version_id,
              interpretation_key: "legacy-forest-approved-label",
              disposition: :approved,
              statement: item.decision.statement
            })

          Council.record_decision_evidence!(%{
            decision_id: legacy.id,
            source_version_id: version_id,
            claim: :decision,
            excerpt: evidence.excerpt,
            location: evidence.location,
            citation_url: evidence.citation_url,
            retrieved_at: evidence.retrieved_at
          })

          item =
            Council.mark_agenda_item_decided!(item, %{
              current_decision_id: legacy.id,
              outcome: :approved
            })

          Council.publish_agenda_item_state!(item)
          legacy
        end

      legacy_revision =
        Council.PublicationLifecycle.factual_correction!(
          page.id,
          bundles,
          %{
            "fr" => "Ancienne interprétation",
            "nl" => "Eerdere interpretatie",
            "en" => "Earlier interpretation"
          },
          actor
        )

      # Replay the corrected, hash-pinned normalizer. This appends interpretations;
      # it must not silently replace the still-published revision or its badges.
      assert :ok = Ingestion.Pipeline.normalize(run.id, source["url"], 1, 3, :backfill)
      assert :ok = Ingestion.Pipeline.normalize(run.id, source["url"], 1, 3, :backfill)

      for legacy <- legacy_decisions do
        item = Council.get_agenda_item!(legacy.agenda_item_id)
        assert item.current_decision_id != legacy.id
        assert item.published_decision_id == legacy.id
        assert item.published_outcome == :approved
        assert Council.get_decision!(legacy.id).disposition == :approved
      end

      notes = %{
        "fr" =>
          "L’étiquette « approuvée » des points 9 et 15 était trop générale : le conseil a approuvé une prise de connaissance des décisions du collège, non les marchés eux-mêmes.",
        "nl" =>
          "Het label ‘goedgekeurd’ bij punten 9 en 15 was te algemeen: de raad keurde een kennisneming van collegebesluiten goed, niet de opdrachten zelf.",
        "en" =>
          "The Approved label on items 9 and 15 was too broad: the council approved acknowledgement of executive decisions, not the underlying contracts."
      }

      review_case =
        BrusselsWtf.Review.open_review_case!(%{
          kind: :evidence,
          commune_id: meeting.commune_id,
          affected_record_id: page.id,
          affected_record_type: "meeting_page",
          processing_generation: "forest-2026-03-24-outcome-audit",
          summary: "Check the operative acknowledgement and approval vote together"
        })

      correct = fn ->
        case correction_kind do
          :editorial ->
            Council.PublicationLifecycle.factual_correction!(page.id, bundles, notes, actor)

          :recorded ->
            Council.Publication.recorded_factual_correction!(
              page.id,
              legacy_revision.id,
              notes,
              actor
            )
        end
      end

      runs_before = Council.list_coverage_runs!(page.id)

      assert_raise ArgumentError, ~r/publication gate failed/, correct

      assert Council.get_meeting_page!(page.id).current_revision_id == legacy_revision.id
      assert Council.list_coverage_runs!(page.id) == runs_before
      assert length(Council.list_publication_revisions!(page.id)) == 2

      for legacy <- legacy_decisions do
        item = Council.get_agenda_item!(legacy.agenda_item_id)
        assert item.published_decision_id == legacy.id
        assert item.published_outcome == :approved
      end

      BrusselsWtf.Review.correct_review_case!(
        review_case,
        %{
          note: notes["en"],
          corrected_content: %{
            "9" => "other",
            "15" => "other",
            "source_sha256" => source["sha256"]
          }
        },
        actor: actor
      )

      if correction_kind == :recorded do
        malformed =
          update_in(
            initial.content,
            ["items", "forest-2026-03-24-15", "variants"],
            &Map.delete(&1, "nl")
          )

        BrusselsWtf.Processors.Stub.put_locales("2026-03-24", malformed)
        Application.put_env(:brussels_wtf, :coverage_processor, BrusselsWtf.Processors.Stub)

        assert_raise ArgumentError, ~r/publication gate failed.*missing_coverage_variant/, correct
        assert Council.get_meeting_page!(page.id).current_revision_id == legacy_revision.id
        assert Council.list_coverage_runs!(page.id) == runs_before

        Application.put_env(
          :brussels_wtf,
          :coverage_processor,
          BrusselsWtf.Processors.RecordedCorpusCoverage
        )
      end

      BrusselsWtf.Clock.Controlled.set(~U[2026-09-11 10:00:00Z])

      corrected =
        if correction_kind == :recorded do
          script = Application.app_dir(:brussels_wtf, "priv/ops/correct_forest_20260324.exs")

          output = ExUnit.CaptureIO.capture_io(fn -> Code.eval_file(script) end)
          assert output =~ "READ ONLY"
          assert Council.get_meeting_page!(page.id).current_revision_id == legacy_revision.id
          assert Council.list_coverage_runs!(page.id) == runs_before

          output =
            ExUnit.CaptureIO.capture_io(fn ->
              Code.eval_string(
                File.read!(script),
                [apply?: true, expected_revision_id: legacy_revision.id, actor_id: actor.id],
                file: script
              )
            end)

          assert output =~ "Forest correction published or already applied"

          page.id
          |> Council.get_meeting_page!()
          |> Ash.load!(:current_revision)
          |> Map.fetch!(:current_revision)
        else
          correct.()
        end

      if correction_kind == :recorded do
        assert corrected.actor_id == actor.id
        assert is_nil(corrected.publication_metadata["content_review"])

        assert Enum.all?(corrected.publication_metadata["provenance"], fn {_locale, labels} ->
                 "human_reviewed" not in labels and "ai_generated" in labels
               end)

        assert corrected.publication_metadata["processors"]["fr"]["method"] == "ai_generation"

        assert corrected.publication_metadata["processors"]["nl"]["method"] ==
                 "machine_translation"

        assert corrected.publication_metadata["processors"]["en"]["method"] ==
                 "machine_translation"

        runs_after = Council.list_coverage_runs!(page.id)
        assert correct.().id == corrected.id
        assert Council.list_coverage_runs!(page.id) == runs_after

        Application.put_env(:brussels_wtf, :coverage_processor, BrusselsWtf.Processors.Stub)
        assert_raise ArgumentError, ~r/stale publication revision/, correct

        Application.put_env(
          :brussels_wtf,
          :coverage_processor,
          BrusselsWtf.Processors.RecordedCorpusCoverage
        )

        assert_raise ArgumentError, ~r/stale publication revision/, fn ->
          Council.Publication.recorded_factual_correction!(
            page.id,
            legacy_revision.id,
            Map.put(notes, "en", "Different correction"),
            actor
          )
        end

        assert Council.list_coverage_runs!(page.id) == runs_after

        generation_config = Application.fetch_env!(:brussels_wtf, :coverage_generation)

        for mode <- [:disabled, :paid] do
          Application.put_env(:brussels_wtf, :coverage_generation, %{
            generation_config
            | mode: mode
          })

          assert_raise ArgumentError, ~r/zero-network recorded generation/, correct
          assert Council.list_coverage_runs!(page.id) == runs_after
        end

        Application.put_env(:brussels_wtf, :coverage_generation, generation_config)

        assert_raise ArgumentError, ~r/stale publication revision/, fn ->
          Council.Publication.recorded_factual_correction!(page.id, initial.id, notes, actor)
        end

        assert_raise ArgumentError, ~r/requires a reviewer/, fn ->
          Council.Publication.recorded_factual_correction!(
            page.id,
            legacy_revision.id,
            notes,
            nil
          )
        end

        assert_raise ArgumentError, ~r/fr, nl, and en/, fn ->
          Council.Publication.recorded_factual_correction!(
            page.id,
            legacy_revision.id,
            Map.delete(notes, "nl"),
            actor
          )
        end
      end

      assert corrected.previous_revision_id == legacy_revision.id
      assert corrected.revision_kind == :factual_correction
      assert corrected.publication_metadata["locales"] == ~w(fr nl en)
      assert corrected.publication_metadata["gate_result"]["ready"]

      for {locale, other, approved} <- [
            {"fr", "autre", "approuvée"},
            {"nl", "andere", "goedgekeurd"},
            {"en", "other", "approved"}
          ] do
        html =
          conn
          |> recycle()
          |> get("/meetings/forest/2026-03-24?lang=#{locale}")
          |> html_response(200)

        document = LazyHTML.from_document(html)
        assert LazyHTML.text(document) =~ notes[locale]
        assert html =~ source["sha256"]

        for legacy <- legacy_decisions do
          item = Council.get_agenda_item!(legacy.agenda_item_id)
          headings = LazyHTML.text(document["article##{item.stable_anchor} h3"])
          assert headings =~ other
          refute headings =~ approved
          assert item.published_decision_id == item.current_decision_id
          assert item.published_outcome == :other
        end
      end

      revisions = Council.list_publication_revisions!(page.id)
      assert Enum.map(revisions, & &1.id) == [initial.id, legacy_revision.id, corrected.id]
      assert Enum.at(revisions, 1).content == legacy_revision.content
      old_input = Ash.load!(Enum.at(revisions, 1), :canonical_run).canonical_run.input
      new_input = Ash.load!(corrected, :canonical_run).canonical_run.input

      for key <- ["forest-2026-03-24-9", "forest-2026-03-24-15"] do
        assert Enum.find(old_input["items"], &(&1["key"] == key))["outcome"] == "approved"
        assert Enum.find(new_input["items"], &(&1["key"] == key))["outcome"] == "other"
      end

      assert Ingestion.get_source_version!(version_id).sha256 == source["sha256"]
      assert BrusselsWtf.HTTP.Stub.requests(source["url"]) == []
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

  defp contract_text(_meeting, source) do
    {text, 0} = System.cmd("pdftotext", ["-layout", Manifest.bundle_path!(source), "-"])
    text
  end
end
