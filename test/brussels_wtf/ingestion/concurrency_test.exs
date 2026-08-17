defmodule BrusselsWtf.Ingestion.ConcurrencyTest do
  use BrusselsWtf.DataCase, async: false

  test "concurrent attempts append observations and enqueue one downstream chain" do
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
      fn _ -> BrusselsWtf.Ingestion.check_locator(locator.id, poll.id) end,
      max_concurrency: 8,
      ordered: false,
      timeout: 30_000
    )
    |> Enum.each(fn result -> assert {:ok, :ok} = result end)

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :extract, with_safety: false)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :normalize, with_safety: false)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :publish, with_safety: false)

    history = BrusselsWtf.Ingestion.source_history!(scenario.commune.id, source.url)
    assert length(history.observations) == 8
    assert length(history.versions) == 1
    assert length(history.processing_runs) == 1

    meeting = BrusselsWtf.Council.get_ingested_meeting!("ixelles", "268")
    assert length(meeting.agendas) == 1
    assert [%{outcome: :unknown}] = meeting.agenda_items
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
