defmodule BrusselsWtf.Ingestion.IxellesNormalizationIntegrationTest do
  @moduledoc """
  End-to-end proof of the production normalization wiring for one real Ixelles
  council agenda.

  These tests configure the real composite processor
  `BrusselsWtf.Processors.Council` - not a stub - and drive
  `BrusselsWtf.Ingestion.Pipeline.normalize/5` against an accepted extraction
  whose text is the real archived Ixelles meeting 268 complementary agenda
  (`priv/corpus/issue-33/sources/ixelles-268--primary.pdf`, extracted with the
  same `pdftotext -layout` used by the sealed corpus acceptance test).

  The source version bytes are a controlled fixture whose SHA-256 the recorded
  corpus does not know. That is deliberate: it forces the composite past
  `BrusselsWtf.Corpus.Manifest` into the wired Ixelles commune normalizer, so the
  test proves the seam the parent task asked about. The accepted text itself is
  the real document text, not a synthetic summary.
  """

  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.{Council, Ingestion}
  alias BrusselsWtf.Corpus.Manifest
  alias BrusselsWtf.Processors.Council, as: CouncilProcessor
  alias BrusselsWtf.Processors.IxellesCouncil

  @ixelles_origin "https://www.ixelles.be/uploads/conseil/odj/268.pdf"
  @ixelles_parent_index "https://www.ixelles.be/site/11-Ordres-du-jour-et-proces-verbaux?langue=fr"

  setup do
    previous_processors = Application.fetch_env!(:brussels_wtf, :processors)
    previous_time = BrusselsWtf.Clock.utc_now()

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :processors, previous_processors)
      BrusselsWtf.Clock.Controlled.set(previous_time)
    end)

    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-08-21 02:30:00Z])
    :ok
  end

  test "real Ixelles 268 agenda normalizes through the composite into persisted proposals" do
    commune =
      Ingestion.create_commune!(%{
        slug: "ixelles",
        name: "Ixelles",
        index_url: "https://example.test/ixelles"
      })

    assert real_agenda_text() =~ "ORDRE DU JOUR COMPLÉMENTAIRE"

    {version, run} =
      accepted_run(commune, "ixelles", @ixelles_origin, real_agenda_text(),
        meeting_identifier: "268",
        scheduled_on: ~D[2026-07-02],
        role: :agenda,
        language: :bilingual
      )

    assert run.status == :succeeded
    assert run.quality_measurements["accepted"]

    # Only now switch the processor seam to the real composite. Extraction above
    # uses the fixture stub, exactly like the other ingestion tests.
    Application.put_env(:brussels_wtf, :processors, CouncilProcessor)

    assert :ok = Ingestion.Pipeline.normalize(run.id, @ixelles_origin, 1, 3, :backfill)

    assert [] =
             BrusselsWtf.Review.list_review_cases!(%{}, authorize?: false)

    meeting = Council.get_ingested_meeting!("ixelles", "268")
    assert meeting.commune.slug == "ixelles"
    assert meeting.municipal_identifier == "268"
    assert meeting.scheduled_on == ~D[2026-07-02]

    [agenda] = meeting.agendas
    assert agenda.kind == :complementary
    assert agenda.language == :bilingual
    assert agenda.source_version_id == version.id

    # The real archived agenda is the official complementary agenda supplied with
    # 108 numbered points. This count is a regression signal for the wired parser.
    items = meeting.agenda_items
    assert length(items) == 108
    assert Enum.map(items, & &1.item_number) |> Enum.sort() |> hd() == "1"

    # Every item is a proposal or an unknown-outcome information point. No agenda
    # ever yields a decision.
    assert Enum.all?(items, &(&1.outcome == :unknown))
    assert Enum.all?(items, &is_nil(&1.decision))
    refute Enum.any?(items, &(&1.procedural_state == :decision))

    proposal_items = Enum.filter(items, &(&1.proposals != []))
    assert length(proposal_items) > 100

    assert Enum.all?(proposal_items, &(&1.procedural_state == :proposal))
    assert Enum.all?(items -- proposal_items, &(&1.procedural_state == :unknown))

    # Proposals carry real evidence, and every excerpt really occurs in the
    # accepted page text.
    assert Enum.all?(proposal_items, fn item ->
             Enum.all?(item.proposals, fn proposal ->
               proposal.status == :proposed and
                 not proposal.synthetic and
                 Enum.all?(proposal.evidence, fn evidence ->
                   evidence.claim == :proposal and
                     not evidence.synthetic and
                     evidence.citation_url == @ixelles_origin and
                     evidence.excerpt == proposal.text and
                     IxellesCouncil.verify_excerpt(evidence.excerpt, real_agenda_text()) == :ok
                 end)
             end)
           end)

    # The official complementary agenda point 4 is the real "La venue de
    # l'avenir" grant; its wording is the archived French text.
    point_four = Enum.find(items, &(&1.item_number == "4"))
    assert point_four.source_wording =~ "La venue de l’avenir"

    [proposal] = point_four.proposals
    assert proposal.text == point_four.source_wording
    [evidence] = proposal.evidence
    assert evidence.location == "Ordre du jour complémentaire, point 4, page 2/25"
    assert evidence.applicable_from == ~D[2026-07-02]
    assert IxellesCouncil.verify_excerpt(evidence.excerpt, real_agenda_text()) == :ok

    # A meeting page exists and stays unknown until authoritative final records.
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
    assert page.council_meeting_id == meeting.id
    assert page.citation_url == @ixelles_origin
    assert page.procedural_state == :unknown
    assert page.publication_status == :draft

    # A backfill must never enqueue paid publication work.
    refute_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)
  end

  test "an automatic generation enqueues the publication job a backfill suppresses" do
    commune =
      Ingestion.create_commune!(%{
        slug: "ixelles",
        name: "Ixelles",
        index_url: "https://example.test/ixelles"
      })

    {_version, run} =
      accepted_run(commune, "ixelles", @ixelles_origin, real_agenda_text(),
        meeting_identifier: "268",
        scheduled_on: ~D[2026-07-02],
        role: :agenda,
        language: :bilingual
      )

    Application.put_env(:brussels_wtf, :processors, CouncilProcessor)

    assert :ok = Ingestion.Pipeline.normalize(run.id, @ixelles_origin, 1, 3, :automatic)

    assert_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)
  end

  test "the same real text is not normalized without the locator context" do
    commune =
      Ingestion.create_commune!(%{
        slug: "ixelles",
        name: "Ixelles",
        index_url: "https://example.test/ixelles"
      })

    {_version, run} =
      accepted_run(commune, "ixelles", @ixelles_origin, real_agenda_text(),
        meeting_identifier: "268",
        scheduled_on: ~D[2026-07-02],
        role: :agenda,
        language: :bilingual,
        locator?: false
      )

    Application.put_env(:brussels_wtf, :processors, CouncilProcessor)

    assert :ok = Ingestion.Pipeline.normalize(run.id, @ixelles_origin, 1, 3, :backfill)

    # Identity can only come from the discovery context, so without a locator the
    # normalizer fails closed into one review case instead of guessing.
    assert [review_case] =
             BrusselsWtf.Review.list_review_cases!(%{kind: :normalization, status: :open},
               authorize?: false
             )

    assert review_case.diagnostics["classification"] == "processor_unavailable"
    assert {:error, _} = Council.get_ingested_meeting("ixelles", "268")
    refute_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)
  end

  test "an unseen Forest origin fails closed with one review case and no crash" do
    commune =
      Ingestion.create_commune!(%{
        slug: "forest",
        name: "Forest",
        index_url: "https://example.test/forest"
      })

    origin = "https://example.test/forest/agenda.pdf"

    {_version, run} =
      accepted_run(commune, "forest", origin, forest_text(),
        meeting_identifier: "2026-07-02",
        scheduled_on: ~D[2026-07-02],
        role: :agenda,
        language: :fr
      )

    Application.put_env(:brussels_wtf, :processors, CouncilProcessor)

    # The composite itself is explicit about the missing normalizer.
    assert {:error, :processor_unimplemented} =
             CouncilProcessor.normalize(%{
               "commune_slug" => "forest",
               "sha256" => "unseen-forest-sha256",
               "text" => forest_text()
             })

    assert {:error, :processor_unimplemented} =
             CouncilProcessor.normalize(%{
               "commune_slug" => "city-of-brussels",
               "sha256" => "unseen-city-sha256",
               "text" => forest_text()
             })

    # The pipeline converts that deterministic failure into exactly one private
    # normalization case instead of crashing or retrying forever.
    assert :ok = Ingestion.Pipeline.normalize(run.id, origin, 1, 3, :backfill)

    assert [review_case] =
             BrusselsWtf.Review.list_review_cases!(%{kind: :normalization, status: :open},
               authorize?: false
             )

    assert review_case.commune_id == commune.id
    assert review_case.affected_record_type == "source_version"
    assert review_case.processing_generation == "normalization:#{run.id}"

    assert review_case.diagnostics == %{
             "classification" => "processor_unavailable",
             "detail" => "No production normalizer is configured"
           }

    assert {:error, _} = Council.get_ingested_meeting("forest", "2026-07-02")
    refute_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)
  end

  # Creates an archived source version with one accepted native-text artifact and
  # returns the succeeded native-extraction run. The extracted text is supplied by
  # the fixture stub; the source version hash is deliberately unknown to the
  # recorded corpus so the composite delegates to the commune normalizer.
  defp accepted_run(commune, _slug, origin, text, opts) do
    bytes = "%PDF controlled normalization integration fixture #{origin}"

    {:ok, archived} = BrusselsWtf.Archive.store(bytes)

    record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: origin,
        role: :agenda,
        original_language: Keyword.fetch!(opts, :language)
      })

    version =
      Ingestion.upsert_source_version!(%{
        source_record_id: record.id,
        sha256: archived.sha256,
        byte_size: byte_size(bytes),
        media_type: "application/pdf",
        object_key: archived.object_key,
        first_retrieved_at: BrusselsWtf.Clock.utc_now()
      })

    if Keyword.get(opts, :locator?, true) do
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: origin,
        parent_index_url: parent_index(commune.slug),
        meeting_identifier: Keyword.fetch!(opts, :meeting_identifier),
        scheduled_on: Keyword.fetch!(opts, :scheduled_on),
        role: Keyword.fetch!(opts, :role),
        language: Keyword.fetch!(opts, :language),
        observed_label: "Ordre du jour du conseil communal",
        discovered_at: BrusselsWtf.Clock.utc_now()
      })
    end

    BrusselsWtf.Processors.Stub.put(version.sha256, %{
      extract: %{"text" => text, "page_texts" => [text]}
    })

    assert :ok = Ingestion.Pipeline.extract(version.id, 1, :backfill)

    run =
      version.id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.find(&(&1.status == :succeeded and &1.processor_role == :native_extraction))

    {version, run}
  end

  defp parent_index("ixelles"), do: @ixelles_parent_index
  defp parent_index(_slug), do: "https://example.test/parent-index"

  # Real archived text of the official Ixelles 268 complementary agenda, extracted
  # with the same command the sealed corpus acceptance test uses.
  defp real_agenda_text do
    [source] =
      Manifest.meeting!("ixelles-268")["sources"]
      |> Enum.filter(&(&1["name"] == "primary"))

    {text, 0} = System.cmd("pdftotext", ["-layout", Manifest.bundle_path!(source), "-"])
    text
  end

  defp forest_text do
    "Conseil communal de Forest - ordre du jour public du 2 juillet 2026. " <>
      "Toekenning en goedkeuring van de agenda met voldoende tekst voor extractie."
  end
end
