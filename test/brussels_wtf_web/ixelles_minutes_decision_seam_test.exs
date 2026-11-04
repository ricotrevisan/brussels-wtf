defmodule BrusselsWtfWeb.IxellesMinutesDecisionSeamTest do
  @moduledoc """
  The principal seam of the Ixelles minutes normalizer: an agenda and later minutes in the
  observed layout enter through the real composite processor, and the published meeting
  page moves from proposal to documented decision at the same URL with dated history.
  """

  use BrusselsWtfWeb.ConnCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  import BrusselsWtf.Test.IxellesMinutesFixture

  alias BrusselsWtf.{Council, Ingestion, Review}
  alias BrusselsWtf.Ingestion.IxellesMinutesBackfill
  alias BrusselsWtf.Processors.Council, as: CouncilProcessor
  alias BrusselsWtf.Processors.Stub

  @date ~D[2026-05-21]
  @agenda_url "https://www.ixelles.be/uploads/conseil/odj/266.pdf"
  @minutes_url "https://www.ixelles.be/uploads/conseil/pv/266.pdf"
  @path "/meetings/ixelles/266"

  @budget "Budget 2026. Approbation."
  @motion "Proposition de motion relative à la gestion de l'asbl."
  @grant "Octroi d'une subvention de projet en numéraire. Approbation."
  @question "Question orale de M. Deux, Conseiller communal, relative au parc."

  @agenda_text """
                                                                                  COMMUNE D'IXELLES
                                                                                   GEMEENTE ELSENE

                                              CONSEIL COMMUNAL DU 21 MAI 2026
                                               GEMEENTERAAD VAN 21 MEI 2026

                                                       ORDRE DU JOUR
                                                          AGENDA

      Affaires générales - Algemene zaken

      1       #{@budget}
            Begroting 2026. Goedkeuring.

      2       #{@motion}
            Voorstel van motie betreffende het beheer van de vzw.

      3       #{@grant}
            Toekenning van een projectsubsidie. Goedkeuring.

      4       #{@question}
            Mondelinge vraag van dhr. Twee, gemeenteraadslid, betreffende het park.

  Conseil communal - 21.05.2026 - Ordre du jour
  Gemeenteraad - 21.05.2026 - Agenda                                                               1/1
  """

  setup do
    previous_processors = Application.fetch_env!(:brussels_wtf, :processors)
    previous_time = BrusselsWtf.Clock.utc_now()

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :processors, previous_processors)
      BrusselsWtf.Clock.Controlled.set(previous_time)
    end)

    BrusselsWtf.Archive.Memory.reset()
    Stub.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-05-20 08:00:00Z])

    commune =
      Ingestion.create_commune!(%{
        slug: "ixelles",
        name: "Ixelles",
        index_url: "https://www.ixelles.be/site/11-Ordres-du-jour-et-proces-verbaux?langue=fr"
      })

    {:ok, commune: commune}
  end

  test "a published proposal becomes a cited decision on the same URL, keeping its anchor and history",
       %{commune: commune, conn: conn} do
    proposed = publish_agenda(commune)

    budget_before = item!(proposed, "1")
    assert budget_before.procedural_state == :proposal
    assert budget_before.published_procedural_state == :proposal
    anchor = budget_before.stable_anchor

    page = proposed |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
    assert [proposal_revision] = Council.list_publication_revisions!(page.id)

    before_html = conn |> get(@path <> "?lang=en") |> html_response(200)
    assert before_html =~ anchor
    refute before_html =~ "24 against"

    BrusselsWtf.Clock.Controlled.set(~U[2026-06-20 08:00:00Z])
    run = accepted_run(commune, @minutes_url, minutes_text(), :minutes)
    Application.put_env(:brussels_wtf, :processors, CouncilProcessor)

    assert :ok = Ingestion.Pipeline.normalize(run.id, @minutes_url)

    # The new outcome stays private until the complete revision passes the gate.
    staged = Council.get_published_meeting_page!("ixelles", "266")
    assert item!(staged.council_meeting, "1").procedural_state == :decision
    assert item!(staged.council_meeting, "1").published_procedural_state == :proposal

    Stub.put_locales("266", coverage(:decision))
    assert_publish_drains()

    final = Council.get_ingested_meeting!("ixelles", "266")
    budget = item!(final, "1")

    assert budget.id == budget_before.id
    assert budget.stable_anchor == anchor
    assert budget.authoritative_identifier == "1"
    assert budget.outcome == :approved
    assert [%{status: :proposed}] = budget.proposals

    assert %{disposition: :approved, statement: "Le Conseil approuve.", votes_for: 35} =
             budget.decision

    assert {budget.decision.votes_against, budget.decision.abstentions} == {0, 0}
    assert Enum.sort(Enum.map(budget.decision.evidence, & &1.claim)) == [:decision, :vote]
    assert Enum.all?(budget.decision.evidence, &(&1.citation_url == @minutes_url))

    motion = item!(final, "2")
    assert motion.outcome == :rejected
    assert {motion.decision.votes_for, motion.decision.votes_against} == {15, 24}

    # The unmatched point is unknown; the non-votable one has no decision.
    grant = item!(final, "3")
    assert {grant.procedural_state, grant.outcome, grant.decision} == {:proposal, :unknown, nil}
    question = item!(final, "4")

    assert {question.procedural_state, question.outcome, question.decision} ==
             {:unknown, :unknown, nil}

    revised = final |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
    assert revised.id == page.id
    assert revised.publication_status == :published
    revisions = Council.list_publication_revisions!(page.id)
    assert length(revisions) == 2
    assert Enum.any?(revisions, &(&1.id == proposal_revision.id))

    for {locale, vote} <- [{"fr", "35 pour"}, {"nl", "35 voor"}, {"en", "35 for"}] do
      html = build_conn() |> get(@path <> "?lang=#{locale}") |> html_response(200)
      assert html =~ anchor
      assert html =~ vote
      assert html =~ @minutes_url
    end

    contested = build_conn() |> get("/coverage/contested-votes?lang=en") |> html_response(200)
    assert contested =~ @path
    assert contested =~ motion.stable_anchor

    # The published page still says unknown about the point the minutes could not resolve.
    english = build_conn() |> get(@path <> "?lang=en") |> html_response(200)
    assert english =~ grant.stable_anchor
    assert english =~ "Unknown outcome"
  end

  test "unresolved points are counted in one case that does not block the page", %{
    commune: commune
  } do
    publish_agenda(commune)

    BrusselsWtf.Clock.Controlled.set(~U[2026-06-20 08:00:00Z])
    run = accepted_run(commune, @minutes_url, minutes_text(), :minutes)
    Application.put_env(:brussels_wtf, :processors, CouncilProcessor)

    assert :ok = Ingestion.Pipeline.normalize(run.id, @minutes_url)

    assert [review_case] =
             %{kind: :normalization}
             |> Review.list_review_cases!(authorize?: false)
             |> Enum.filter(&(&1.status == :open))

    assert review_case.summary == "1 of 4 minutes points stay unknown"
    assert review_case.diagnostics["classification"] == "minutes_items_unmatched"

    assert review_case.normalized_content["unmatched"] == [
             %{"identifier" => "21.05.2026/A/0003", "reason" => "wording_differs"}
           ]

    meeting = Council.get_ingested_meeting!("ixelles", "266") |> Ash.load!(:meeting_page)
    assert Review.list_blocking_publication_cases!(meeting) == []
  end

  test "an earlier unavailable case on the minutes is resolved, while any other case still blocks",
       %{commune: commune} do
    publish_agenda(commune)

    BrusselsWtf.Clock.Controlled.set(~U[2026-06-20 08:00:00Z])
    run = accepted_run(commune, @minutes_url, minutes_text(), :minutes)

    # What production holds today: minutes that met no normalizer.
    Ingestion.NormalizationReview.open_for_run(
      Ash.load!(run, source_version: [:source_record]),
      @minutes_url
    )

    Application.put_env(:brussels_wtf, :processors, CouncilProcessor)
    assert :ok = Ingestion.Pipeline.normalize(run.id, @minutes_url)

    open =
      %{kind: :normalization}
      |> Review.list_review_cases!(authorize?: false)
      |> Enum.filter(&(&1.status == :open))

    assert [%{diagnostics: %{"classification" => "minutes_items_unmatched"}}] = open

    meeting = Council.get_ingested_meeting!("ixelles", "266") |> Ash.load!(:meeting_page)
    assert Review.list_blocking_publication_cases!(meeting) == []

    version = Ash.load!(run, source_version: [:source_record]).source_version

    other =
      Review.open_review_case!(%{
        kind: :normalization,
        commune_id: commune.id,
        affected_record_id: version.id,
        affected_record_type: "source_version",
        source_record_id: version.source_record_id,
        source_version_id: version.id,
        processing_generation: "another-ambiguity",
        urgency: :high,
        summary: "Another ambiguity",
        diagnostics: %{"classification" => "normalization_ambiguity"}
      })

    assert [blocking] = Review.list_blocking_publication_cases!(meeting)
    assert blocking.id == other.id
  end

  test "a whole-document ambiguity records nothing and stays a review case", %{commune: commune} do
    publish_agenda(commune)
    before = Council.get_ingested_meeting!("ixelles", "266")

    BrusselsWtf.Clock.Controlled.set(~U[2026-06-20 08:00:00Z])

    run =
      accepted_run(
        commune,
        @minutes_url,
        String.replace(minutes_text(), "Levée de la séance", "Fin"),
        :minutes
      )

    Application.put_env(:brussels_wtf, :processors, CouncilProcessor)
    assert :ok = Ingestion.Pipeline.normalize(run.id, @minutes_url)

    after_read = Council.get_ingested_meeting!("ixelles", "266")

    assert Enum.map(after_read.agenda_items, & &1.outcome) ==
             Enum.map(before.agenda_items, & &1.outcome)

    refute Enum.any?(after_read.agenda_items, & &1.decision)

    assert [%{diagnostics: %{"classification" => "normalization_ambiguity"}}] =
             %{kind: :normalization}
             |> Review.list_review_cases!(authorize?: false)
             |> Enum.filter(&(&1.status == :open))
  end

  describe "the bounded operator requeue" do
    setup %{commune: commune} do
      publish_agenda(commune)
      BrusselsWtf.Clock.Controlled.set(~U[2026-06-20 08:00:00Z])
      run = accepted_run(commune, @minutes_url, minutes_text(), :minutes)
      Application.put_env(:brussels_wtf, :processors, CouncilProcessor)
      {:ok, run: run}
    end

    test "a dry run reports the reading and writes nothing", %{run: run} do
      outcomes = fn ->
        Council.get_ingested_meeting!("ixelles", "266").agenda_items
        |> Enum.map(&{&1.id, &1.outcome, &1.current_source_version_id})
        |> Enum.sort()
      end

      before = outcomes.()

      {entries, output} =
        ExUnit.CaptureIO.with_io(fn -> IxellesMinutesBackfill.dry_run() end)

      assert [%{status: :ready, meeting_identifier: "266"} = entry] = entries
      assert entry.run.id == run.id

      assert entry.reading == %{
               "points" => 4,
               "decided" => 2,
               "non_votable" => 1,
               "minutes_only" => 0,
               "contested" => 1,
               "unmatched" => [
                 %{"identifier" => "21.05.2026/A/0003", "reason" => "wording_differs"}
               ]
             }

      assert output =~ "dry run: nothing written"
      assert output =~ "266 2026-05-21 ready points=4 decided=2"
      assert output =~ "21.05.2026/A/0003:wording_differs"

      assert outcomes.() == before
      refute_enqueued(worker: BrusselsWtf.Workers.NormalizeSource)
      assert %{kind: :normalization} |> Review.list_review_cases!(authorize?: false) == []
    end

    test "a requeue queues the window once under the current contract and publishes after it", %{
      run: run
    } do
      contract = BrusselsWtf.Processors.normalization_contract()

      {[entry], _output} = ExUnit.CaptureIO.with_io(fn -> IxellesMinutesBackfill.requeue() end)
      assert entry.queued

      assert_enqueued(
        worker: BrusselsWtf.Workers.NormalizeSource,
        args: %{
          processing_run_id: run.id,
          locator_url: @minutes_url,
          processor_contract: contract,
          generation_kind: "automatic"
        }
      )

      Stub.put_locales("266", coverage(:decision))
      assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :normalize, with_safety: false)
      assert_publish_drains()

      {[receipt], output} = ExUnit.CaptureIO.with_io(fn -> IxellesMinutesBackfill.receipt() end)
      assert {receipt.recorded, receipt.published, receipt.revisions} == {2, 2, 2}
      assert output =~ "recorded=2 published=2 revisions=2"
    end

    test "a held native-only recovery is reported and never queued", %{run: run} do
      import Ecto.Query

      BrusselsWtf.Repo.update_all(
        from(r in "processing_runs", where: r.id == type(^run.id, Ecto.UUID)),
        set: [inputs: Map.put(run.inputs, "extraction_only", true)]
      )

      {[entry], output} = ExUnit.CaptureIO.with_io(fn -> IxellesMinutesBackfill.requeue() end)

      assert entry.status == :extraction_only_hold
      refute Map.has_key?(entry, :queued)
      assert output =~ "266 2026-05-21 extraction_only_hold"
      refute_enqueued(worker: BrusselsWtf.Workers.NormalizeSource)
    end

    test "a meeting outside the window is not read", %{} do
      assert [] = IxellesMinutesBackfill.plan(since: ~D[2026-06-01])
    end
  end

  defp minutes_text do
    document(
      [
        Map.merge(%{number: 1, wording: @budget}, approved(35)),
        %{
          number: 2,
          wording: @motion,
          lines: [
            "Le point est rejeté.",
            "39 votants : 15 votes positifs, 24 votes négatifs.",
            "Non : Membre Un, Membre Deux."
          ],
          dutch_lines: [
            "Het punt wordt verworpen.",
            "39 stemmers : 15 positieve stemmen, 24 negatieve stemmen."
          ]
        },
        # Retitled in session: the same number no longer provably means the same matter.
        Map.merge(
          %{number: 3, wording: "Octroi d'une autre subvention. Approbation."},
          approved(35)
        ),
        %{
          number: 4,
          wording: @question,
          lines: ["Le point est reporté."],
          dutch_lines: ["Het punt wordt verdaagd."]
        }
      ],
      date: @date
    )
  end

  defp publish_agenda(commune) do
    run = accepted_run(commune, @agenda_url, @agenda_text, :agenda)
    Application.put_env(:brussels_wtf, :processors, CouncilProcessor)
    Stub.put_locales("266", coverage(:proposal))

    assert :ok = Ingestion.Pipeline.normalize(run.id, @agenda_url)
    assert_publish_drains()

    Application.put_env(:brussels_wtf, :processors, Stub)
    meeting = Council.get_ingested_meeting!("ixelles", "266")

    assert meeting
           |> Ash.load!(:meeting_page)
           |> Map.fetch!(:meeting_page)
           |> Map.fetch!(:publication_status) == :published

    meeting
  end

  defp assert_publish_drains do
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :publish, with_safety: false)
  end

  defp item!(meeting, number), do: Enum.find(meeting.agenda_items, &(&1.item_number == number))

  defp coverage(stage) do
    %{
      "page" =>
        Map.new(~w(fr nl en), fn locale ->
          {locale, %{"title" => "Conseil du 21 mai #{locale}", "summary" => "Résumé #{locale}"}}
        end),
      "items" =>
        for {number, kinds} <- coverage_items(stage), into: %{} do
          {"@item_number:" <> number,
           %{"claim_refs" => claim_refs(number, stage), "variants" => variants(number, kinds)}}
        end
    }
  end

  defp coverage_items(:proposal), do: [{"1", [:proposal]}, {"2", [:proposal]}, {"3", [:proposal]}]

  defp coverage_items(:decision),
    do: [{"1", [:proposal, :decision]}, {"2", [:proposal, :decision]}, {"3", [:proposal]}]

  defp claim_refs("3", _stage), do: [proposal_ref()]
  defp claim_refs(_number, :proposal), do: [proposal_ref()]

  defp claim_refs(_number, :decision),
    do: [proposal_ref(), "decision:@item_key:#{sha(@minutes_url)}"]

  defp proposal_ref, do: "proposal:@item_key:#{sha(@agenda_url)}"

  defp sha(origin), do: BrusselsWtf.Digest.sha256(pdf_bytes(origin))

  defp variants(number, kinds) do
    Map.new(~w(fr nl en), fn locale ->
      base = %{"title" => "Point #{number} #{locale}", "summary" => "Résumé #{number} #{locale}"}

      base =
        if :proposal in kinds,
          do: Map.put(base, "proposal_summary", "Proposé #{locale}"),
          else: base

      base =
        if :decision in kinds,
          do: Map.put(base, "decision_summary", "Décidé #{locale}"),
          else: base

      {locale, base}
    end)
  end

  defp pdf_bytes(origin), do: "%PDF controlled Ixelles minutes seam fixture #{origin}"

  defp accepted_run(commune, origin, text, role) do
    bytes = pdf_bytes(origin)
    {:ok, archived} = BrusselsWtf.Archive.store(bytes)

    record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: origin,
        role: role,
        original_language: :bilingual
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

    Ingestion.upsert_locator!(%{
      commune_id: commune.id,
      url: origin,
      parent_index_url: commune.index_url,
      meeting_identifier: "266",
      scheduled_on: @date,
      role: role,
      language: :bilingual,
      observed_label: "Conseil communal",
      discovered_at: BrusselsWtf.Clock.utc_now()
    })

    Stub.put(version.sha256, %{extract: %{"text" => text, "page_texts" => [text]}})
    assert :ok = Ingestion.Pipeline.extract(version.id, 1, :backfill)

    # Each test decides when normalization runs; the job extraction queued is not part of it.
    BrusselsWtf.Repo.delete_all(Oban.Job)

    version.id
    |> Ingestion.get_source_version!()
    |> Ash.load!(:processing_runs)
    |> Map.fetch!(:processing_runs)
    |> Enum.find(&(&1.status == :succeeded and &1.processor_role == :native_extraction))
  end
end
