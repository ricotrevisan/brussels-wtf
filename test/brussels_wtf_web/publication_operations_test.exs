defmodule BrusselsWtfWeb.PublicationOperationsTest do
  use BrusselsWtfWeb.ConnCase, async: false
  alias BrusselsWtf.{Council, Ingestion, Review, Suggestions}
  @reviewer %Review.Actor{id: "rico", role: :reviewer}
  @coverage_copy [
    {"en", "Retained documents: 1", "Cited by this revision: 1",
     "Source or publication awaiting"},
    {"fr", "Documents conservés\u00A0: 1", "Cités par cette révision\u00A0: 1",
     "Source ou publication en attente"},
    {"nl", "Bewaarde documenten: 1", "Geciteerd in deze revisie: 1", "Bron of publicatie wacht"}
  ]

  setup do
    config = Application.fetch_env!(:brussels_wtf, :suggestions)

    Application.put_env(
      :brussels_wtf,
      :suggestions,
      config
      |> Keyword.put(:enabled, true)
      |> Keyword.put(:rate_limit_secret, String.duplicate("private-intake-test", 3))
    )

    on_exit(fn -> Application.put_env(:brussels_wtf, :suggestions, config) end)
    :ok
  end

  test "an item report can be addressed only through a later matching published revision" do
    BrusselsWtf.Test.Harness.load("ixelles/final-267")
    assert :ok = Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()
    {:ok, page} = Council.get_published_meeting_page("ixelles", "267")
    item = hd(page.council_meeting.agenda_items)
    BrusselsWtf.Clock.Controlled.set(DateTime.add(BrusselsWtf.Clock.utc_now(), 1))

    assert {:ok, :accepted} =
             Suggestions.submit(
               %{
                 kind: :correction,
                 subject_type: :agenda_item,
                 subject_reference: item.id,
                 body: "Please update this item when its final minutes are available."
               },
               client_address: "192.0.2.61"
             )

    [suggestion] = Ash.read!(Review.Suggestion, actor: @reviewer)

    assert {:error, :revision_not_published_or_matching} =
             Suggestions.address(
               suggestion.id,
               page.current_revision_id,
               "This revision predates the report.",
               @reviewer
             )

    assert :ok = BrusselsWtf.Test.Harness.advance("final")
    assert :ok = Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()
    {:ok, corrected} = Council.get_published_meeting_page("ixelles", "267")

    assert {:ok, %{status: :addressed}} =
             Suggestions.address(
               suggestion.id,
               corrected.current_revision_id,
               "The final minutes are now reflected in the three published languages.",
               @reviewer
             )

    assert {:error, :already_decided} =
             Suggestions.address(
               suggestion.id,
               corrected.current_revision_id,
               "Duplicate attempt must not change the audit.",
               @reviewer
             )

    [decision] = Ash.read!(Review.SuggestionDecision, actor: @reviewer)
    assert decision.publication_revision_id == corrected.current_revision_id
    assert decision.action == :address
    assert decision.verified_fact_id == nil

    assert Review.get_review_case!(suggestion.review_case_id, actor: @reviewer).disposition ==
             :suggestion_addressed

    Ecto.Adapters.SQL.query!(BrusselsWtf.Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
  end

  test "stale normalization creates one generation-specific case without reopening a resolved case" do
    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    run =
      Ash.read!(Ingestion.ProcessingRun)
      |> Enum.find(&(&1.status == :succeeded and &1.processor_role == :native_extraction))

    job = %Oban.Job{
      args: %{
        "processing_run_id" => run.id,
        "locator_url" => "https://www.ixelles.be/",
        "processor_contract" => "old-contract"
      },
      attempt: 1
    }

    assert {:discard, _} = BrusselsWtf.Workers.NormalizeSource.perform(job)
    assert {:discard, _} = BrusselsWtf.Workers.NormalizeSource.perform(job)

    cases =
      Ash.read!(Review.Case, actor: @reviewer)
      |> Enum.filter(
        &(&1.processing_generation == "normalization-contract:#{run.id}:old-contract")
      )

    assert [review_case] = cases

    Review.correct_review_case!(
      review_case,
      %{
        note: "Current source interpretation has been checked.",
        corrected_content: %{"resolved_by" => "current_contract_check"}
      },
      actor: @reviewer
    )

    assert {:discard, _} = BrusselsWtf.Workers.NormalizeSource.perform(job)
    assert Review.get_review_case!(review_case.id, actor: @reviewer).status == :resolved
  end

  test "same-day agenda has an explicit localized label", %{conn: conn} do
    BrusselsWtf.Test.Harness.load("ixelles/final-267")
    assert :ok = Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()
    BrusselsWtf.Clock.Controlled.set(~U[2026-06-11 10:00:00Z])

    for {locale, label} <- [
          {"en", "Scheduled today"},
          {"fr", "Prévu aujourd’hui"},
          {"nl", "Vandaag gepland"}
        ] do
      assert conn |> get("/?lang=#{locale}") |> html_response(200) =~ label
      assert conn |> get("/meetings/ixelles/267?lang=#{locale}") |> html_response(200) =~ label
    end
  end

  test "published agenda exposes newly retained final minutes awaiting processing", %{conn: conn} do
    BrusselsWtf.Test.Harness.load("ixelles/final-267")
    assert :ok = Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()
    date = BrusselsWtfWeb.MeetingTime.today()

    meeting =
      Enum.find(BrusselsWtf.CoverageStatus.snapshot(date).meetings, &(&1["slug"] == "ixelles"))

    assert meeting["published"]
    refute meeting["source_update_pending"]
    assert :ok = BrusselsWtf.Test.Harness.advance("final")
    assert :ok = Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline(until: :fetch)

    meeting =
      Enum.find(BrusselsWtf.CoverageStatus.snapshot(date).meetings, &(&1["slug"] == "ixelles"))

    assert meeting["published"]
    assert meeting["source_update_pending"]
    html = conn |> get("/coverage?lang=en") |> html_response(200)
    assert html =~ "Source retained; processing or publication pending"
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    meeting =
      Enum.find(BrusselsWtf.CoverageStatus.snapshot(date).meetings, &(&1["slug"] == "ixelles"))

    refute meeting["source_update_pending"]
  end

  describe "the coverage status of one meeting" do
    setup do
      BrusselsWtf.Test.Harness.load("ixelles/final-267")
      assert :ok = Ingestion.poll_now("ixelles")
      assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()
      meeting = Council.get_ingested_meeting!("ixelles", "267") |> Ash.load!(:meeting_page)
      assert meeting.meeting_page.publication_status == :published
      %{page: meeting.meeting_page}
    end

    test "a published meeting with nothing open reports its documents without a pending notice",
         %{conn: conn} do
      status = ixelles_status()

      assert status["retained_documents"] == 1
      assert status["cited_documents"] == 1
      assert status["documents_in_review"] == 0
      assert BrusselsWtf.CoverageStatus.notices(status) == []

      for {locale, retained, cited, stale} <- @coverage_copy do
        html = conn |> get("/coverage?lang=#{locale}") |> html_response(200)
        assert html =~ retained
        assert html =~ cited
        refute html =~ stale
      end
    end

    test "a document whose older version the revision cites stays cited, and its newer version is reported",
         %{conn: conn} do
      agenda =
        Ingestion.SourceRecord
        |> Ash.read!(authorize?: false, load: :versions)
        |> Enum.find(&(&1.role == :agenda))

      [cited] = agenda.versions

      Ingestion.upsert_source_version!(%{
        source_record_id: agenda.id,
        sha256: String.duplicate("a", 64),
        byte_size: 1,
        media_type: "application/pdf",
        object_key: "test/newer-version",
        first_retrieved_at: DateTime.add(cited.first_retrieved_at, 1, :day)
      })

      status = ixelles_status()

      assert status["retained_documents"] == 1
      assert status["cited_documents"] == 1
      assert status["source_update_pending"]
      assert BrusselsWtf.CoverageStatus.notices(status) == [:processing_pending]

      html = conn |> get("/coverage?lang=en") |> html_response(200)
      assert html =~ "Cited by this revision: 1"
      assert html =~ "Source retained; processing or publication pending"
    end

    test "a later publication check is named, and is not called a document review",
         %{conn: conn, page: page} do
      Review.open_review_case!(%{
        kind: :publication,
        affected_record_id: page.id,
        affected_record_type: "meeting_page",
        commune_id: Council.get_ingested_meeting!("ixelles", "267").commune_id,
        processing_generation: "sha256:later-input",
        summary: "must stay private"
      })

      status = ixelles_status()

      assert status["publication_review_pending"]
      assert status["documents_in_review"] == 0
      assert BrusselsWtf.CoverageStatus.notices(status) == [:publication_check_pending]

      for {locale, text} <- [
            {"en", "A publication check for this meeting awaits editorial review."},
            {"fr", "Une vérification de publication pour cette réunion attend un contrôle"},
            {"nl", "Een publicatiecontrole voor deze vergadering wacht op redactionele controle."}
          ] do
        html = conn |> get("/coverage?lang=#{locale}") |> html_response(200)
        assert html =~ text
        refute html =~ "must stay private"
      end
    end

    test "a retained document under review is counted, not hidden, and stays apart from cited ones",
         %{conn: conn} do
      assert :ok = BrusselsWtf.Test.Harness.advance("final")
      assert :ok = Ingestion.poll_now("ixelles")
      assert :ok = BrusselsWtf.Test.Harness.drain_pipeline(until: :fetch)

      minutes =
        Ingestion.SourceRecord
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.role == :minutes))

      Review.open_review_case!(%{
        kind: :normalization,
        affected_record_id: minutes.id,
        affected_record_type: "source_record",
        commune_id: minutes.commune_id,
        source_record_id: minutes.id,
        processing_generation: "normalization:fixture",
        summary: "must stay private"
      })

      status = ixelles_status()

      assert status["published"]
      refute status["publication_review_pending"]
      assert status["retained_documents"] == 2
      assert status["cited_documents"] == 1
      assert status["documents_in_review"] == 1
      assert BrusselsWtf.CoverageStatus.notices(status) == []

      html = conn |> get("/coverage?lang=en") |> html_response(200)
      assert html =~ "Awaiting editorial review: 1"
      refute html =~ "A publication check for this meeting"
      refute html =~ "must stay private"
    end
  end

  test "an unpublished meeting names what is holding it, in every language", %{conn: conn} do
    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline(until: :fetch)

    record =
      Ingestion.SourceRecord |> Ash.read!(authorize?: false) |> Enum.find(&(&1.role == :agenda))

    Review.open_review_case!(%{
      kind: :normalization,
      affected_record_id: record.id,
      affected_record_type: "source_record",
      commune_id: record.commune_id,
      source_record_id: record.id,
      processing_generation: "normalization:fixture",
      summary: "must stay private"
    })

    status = ixelles_status()
    refute status["published"]
    assert status["retained_documents"] == 2
    assert status["documents_in_review"] == 1

    assert BrusselsWtf.CoverageStatus.notices(status) ==
             [:document_review_pending, :processing_pending]

    for {locale, held, no_items} <- [
          {"en", "Retained documents for this meeting await editorial review",
           "No agenda points have been normalized for this meeting yet."},
          {"fr", "Des documents conservés pour cette réunion attendent",
           "Aucun point de l’ordre du jour n’a encore été normalisé pour cette réunion."},
          {"nl", "Bewaarde documenten voor deze vergadering wachten",
           "Voor deze vergadering zijn nog geen agendapunten genormaliseerd."}
        ] do
      html = conn |> get("/coverage?lang=#{locale}") |> html_response(200)
      decoded = html |> LazyHTML.from_document() |> LazyHTML.text()
      assert decoded =~ held
      assert decoded =~ no_items
    end
  end

  test "normalized meetings never claim the agenda was not enumerated", %{conn: conn} do
    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()

    for {locale, scope, old} <- [
          {"en", "Counts cover points read from retained documents", "has not been enumerated"},
          {"fr", "Ces chiffres couvrent les points lus dans les documents conservés", "dénombré"},
          {"nl", "Deze aantallen gelden voor punten uit bewaarde documenten", "niet geteld"}
        ] do
      decoded =
        conn
        |> get("/coverage?lang=#{locale}")
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.text()

      assert decoded =~ scope
      refute decoded =~ old
    end
  end

  test "coverage renders discovered sources before a meeting is normalized", %{conn: conn} do
    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline(until: :fetch)

    meeting =
      Enum.find(
        BrusselsWtf.CoverageStatus.snapshot(BrusselsWtfWeb.MeetingTime.today()).meetings,
        &(&1["slug"] == "ixelles")
      )

    assert meeting["published"] == false

    for {locale, commune_name} <- [{"fr", "Ixelles"}, {"nl", "Elsene"}, {"en", "Ixelles"}] do
      assert conn |> get("/coverage?lang=#{locale}") |> html_response(200) =~ commune_name
    end
  end

  test "coverage distinguishes pending processing and archival replay from official checks" do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline(until: :normalize)
    date = BrusselsWtfWeb.MeetingTime.today()
    before = BrusselsWtf.CoverageStatus.snapshot(date)
    commune = Enum.find(before.communes, &(&1["slug"] == "ixelles"))
    assert commune["checked_at"]
    meeting = Enum.find(before.meetings, &(&1["slug"] == "ixelles"))
    assert meeting["downloaded"]
    refute meeting["published"]
    assert meeting["selected_items"] == 0
    assert meeting["omitted_normalized_items"] > 0
    now = DateTime.add(BrusselsWtf.Clock.utc_now(), 3600)
    locator = Ash.read!(Ingestion.SourceLocator) |> Enum.find(&(&1.role == :index))

    poll =
      Ash.create!(Ingestion.PollRun, %{
        commune_id: scenario.commune.id,
        started_at: now,
        kind: :backfill,
        requester_id: "rico",
        target_type: :commune,
        target_id: scenario.commune.id,
        check_key: "archival-replay-check",
        scope: :backfill
      })

    Ingestion.record_observation!(%{
      source_locator_id: locator.id,
      poll_run_id: poll.id,
      check_key: "archival-replay-check",
      observed_at: now,
      status: :success
    })

    after_replay = BrusselsWtf.CoverageStatus.snapshot(date)

    assert Enum.find(after_replay.communes, &(&1["slug"] == "ixelles"))["checked_at"] ==
             commune["checked_at"]
  end

  defp ixelles_status do
    BrusselsWtfWeb.MeetingTime.today()
    |> BrusselsWtf.CoverageStatus.snapshot()
    |> Map.fetch!(:meetings)
    |> Enum.find(&(&1["slug"] == "ixelles"))
  end
end
