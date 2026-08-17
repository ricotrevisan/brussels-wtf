defmodule BrusselsWtf.Ingestion.ConcurrencyTest do
  use BrusselsWtf.DataCase, async: false

  test "same-check concurrency converges while separate checks append history" do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
    source = scenario.sources.agenda

    locator =
      BrusselsWtf.Ingestion.upsert_locator!(%{
        commune_id: scenario.commune.id,
        url: source.url,
        parent_index_url: scenario.index_url,
        meeting_identifier: "268",
        scheduled_on: ~D[2026-07-02],
        role: :agenda,
        language: :bilingual,
        observed_label: "Ordre du jour",
        discovered_at: BrusselsWtf.Clock.utc_now()
      })

    poll =
      BrusselsWtf.Ingestion.start_poll_run!(%{
        commune_id: scenario.commune.id,
        started_at: BrusselsWtf.Clock.utc_now(),
        kind: :poll_now
      })

    1..8
    |> Task.async_stream(
      fn _ -> BrusselsWtf.Ingestion.check_locator(locator.id, poll.id, "scheduled-check-1") end,
      max_concurrency: 8,
      ordered: false,
      timeout: 30_000
    )
    |> Enum.each(fn result -> assert {:ok, :ok} = result end)

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :extract, with_safety: false)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :normalize, with_safety: false)
    history = BrusselsWtf.Ingestion.source_history!(scenario.commune.id, source.url)
    assert [%{check_key: "scheduled-check-1"}] = history.observations

    assert :ok =
             BrusselsWtf.Ingestion.check_locator(locator.id, poll.id, "scheduled-check-2")

    history = BrusselsWtf.Ingestion.source_history!(scenario.commune.id, source.url)

    assert Enum.map(history.observations, & &1.check_key) == [
             "scheduled-check-1",
             "scheduled-check-2"
           ]

    assert length(history.versions) == 1
    assert length(history.processing_runs) == 1

    meeting = BrusselsWtf.Council.get_ingested_meeting!("ixelles", "268")
    assert length(meeting.agendas) == 1
    assert [%{outcome: :unknown}] = meeting.agenda_items
  end

  test "a reused URL preserves each immutable discovery context" do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
    now = BrusselsWtf.Clock.utc_now()

    original =
      BrusselsWtf.Ingestion.upsert_locator!(%{
        commune_id: scenario.commune.id,
        url: scenario.sources.agenda.url,
        parent_index_url: "https://reuse.invalid/index-1",
        meeting_identifier: "meeting-1",
        scheduled_on: ~D[2026-07-02],
        role: :agenda,
        language: :fr,
        observed_label: "Original agenda",
        item_identifier: "item-1",
        discovered_at: now
      })

    reused =
      BrusselsWtf.Ingestion.upsert_locator!(%{
        commune_id: scenario.commune.id,
        url: original.url,
        parent_index_url: "https://reuse.invalid/index-2",
        meeting_identifier: "meeting-2",
        scheduled_on: ~D[2026-09-03],
        role: :minutes,
        language: :nl,
        observed_label: "Later minutes",
        item_identifier: "item-2",
        discovered_at: DateTime.add(now, 60, :second)
      })

    assert reused.id != original.id
    preserved = BrusselsWtf.Ingestion.get_locator!(original.id)
    assert preserved.parent_index_url == "https://reuse.invalid/index-1"
    assert preserved.meeting_identifier == "meeting-1"
    assert preserved.role == :agenda
    assert preserved.observed_label == "Original agenda"

    poll =
      BrusselsWtf.Ingestion.start_poll_run!(%{
        commune_id: scenario.commune.id,
        started_at: now,
        kind: :poll_now
      })

    assert :ok =
             BrusselsWtf.Ingestion.check_locator(original.id, poll.id, "original-context-check")

    assert :ok = BrusselsWtf.Ingestion.check_locator(reused.id, poll.id, "reused-context-check")

    history = BrusselsWtf.Ingestion.source_history!(scenario.commune.id, original.url)

    assert Enum.map(history.observations, & &1.check_key) == [
             "original-context-check",
             "reused-context-check"
           ]
  end

  test "the same exact URL remains a distinct source record in each commune" do
    scenario = BrusselsWtf.Test.Harness.load("ixelles/proposal")
    shared_url = scenario.sources.agenda.url

    other_commune =
      BrusselsWtf.Ingestion.create_commune!(%{
        slug: "shared-url-test",
        name: "Shared URL Test",
        index_url: "https://other.example/index"
      })

    other_locator =
      BrusselsWtf.Ingestion.upsert_locator!(%{
        commune_id: other_commune.id,
        url: shared_url,
        parent_index_url: other_commune.index_url,
        meeting_identifier: "other-268",
        role: :agenda,
        language: :bilingual,
        observed_label: "Shared exact URL",
        discovered_at: BrusselsWtf.Clock.utc_now()
      })

    other_poll =
      BrusselsWtf.Ingestion.start_poll_run!(%{
        commune_id: other_commune.id,
        started_at: BrusselsWtf.Clock.utc_now(),
        kind: :poll_now
      })

    assert :ok = BrusselsWtf.Ingestion.check_locator(other_locator.id, other_poll.id)

    ixelles_locator =
      BrusselsWtf.Ingestion.upsert_locator!(%{
        commune_id: scenario.commune.id,
        url: shared_url,
        parent_index_url: scenario.index_url,
        meeting_identifier: "268",
        role: :agenda,
        language: :bilingual,
        observed_label: "Ordre du jour",
        discovered_at: BrusselsWtf.Clock.utc_now()
      })

    ixelles_poll =
      BrusselsWtf.Ingestion.start_poll_run!(%{
        commune_id: scenario.commune.id,
        started_at: BrusselsWtf.Clock.utc_now(),
        kind: :poll_now
      })

    assert :ok = BrusselsWtf.Ingestion.check_locator(ixelles_locator.id, ixelles_poll.id)

    other_history = BrusselsWtf.Ingestion.source_history!(other_commune.id, shared_url)
    ixelles_history = BrusselsWtf.Ingestion.source_history!(scenario.commune.id, shared_url)

    assert other_history.source_record.id != ixelles_history.source_record.id
    assert [other_version] = other_history.versions
    assert [ixelles_version] = ixelles_history.versions
    assert other_version.source_record_id != ixelles_version.source_record_id
  end
end
