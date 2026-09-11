defmodule BrusselsWtfWeb.PublicationOperationsTest do
  use BrusselsWtfWeb.ConnCase, async: false
  alias BrusselsWtf.{Council, Ingestion, Review, Suggestions}
  @reviewer %Review.Actor{id: "rico", role: :reviewer}

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
end
