defmodule BrusselsWtf.Council.CoverageBatchTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Council
  alias BrusselsWtf.Review.Actor

  setup do
    previous = Application.fetch_env!(:brussels_wtf, :coverage_generation)
    on_exit(fn -> Application.put_env(:brussels_wtf, :coverage_generation, previous) end)

    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :recorded,
      backfill_enabled: true,
      backfill_max_batch_size: 2,
      monthly_budget_cents: nil
    })

    commune =
      BrusselsWtf.Ingestion.create_commune!(%{
        slug: "ixelles",
        name: "Ixelles",
        index_url: "https://example.test/index"
      })

    meetings =
      for identifier <- ["267", "268", "269"] do
        Council.upsert_meeting!(%{
          commune_id: commune.id,
          municipal_identifier: identifier,
          scheduled_on: ~D[2026-08-20]
        })
      end

    {:ok, meetings: meetings, actor: %Actor{id: "rico", role: :reviewer}}
  end

  test "a reviewer persists and queues a bounded meeting allowlist", %{
    meetings: [first, second, _third],
    actor: actor
  } do
    batch = Council.request_coverage_batch!([first.id, second.id], actor: actor)

    assert batch.requester_id == "rico"
    assert batch.meeting_ids == [first.id, second.id]
    assert batch.status == :queued

    assert_enqueued(
      worker: BrusselsWtf.Workers.PublishMeeting,
      args: %{meeting_id: first.id, generation_kind: "backfill", coverage_batch_id: batch.id}
    )

    assert_enqueued(
      worker: BrusselsWtf.Workers.PublishMeeting,
      args: %{meeting_id: second.id, generation_kind: "backfill", coverage_batch_id: batch.id}
    )
  end

  test "coverage batches fail closed when disabled, oversized, or unauthenticated", %{
    meetings: meetings,
    actor: actor
  } do
    assert_raise ArgumentError, ~r/at most 2/, fn ->
      Council.request_coverage_batch!(Enum.map(meetings, & &1.id), actor: actor)
    end

    assert_raise ArgumentError, ~r/reviewer/, fn ->
      Council.request_coverage_batch!([hd(meetings).id], actor: %{id: "system", role: :system})
    end

    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :recorded,
      backfill_enabled: false,
      backfill_max_batch_size: 2,
      monthly_budget_cents: nil
    })

    assert_raise ArgumentError, ~r/disabled/, fn ->
      Council.request_coverage_batch!([hd(meetings).id], actor: actor)
    end
  end
end
