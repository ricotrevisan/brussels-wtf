defmodule BrusselsWtf.Ingestion.ScheduledPollingTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Ingestion

  setup do
    BrusselsWtf.Clock.Controlled.set(~U[2026-08-20 12:00:00Z])

    commune =
      Ingestion.create_commune!(%{
        slug: "ixelles",
        name: "Ixelles",
        index_url: "https://example.test/index"
      })

    {:ok, commune: commune}
  end

  test "PostgreSQL locator timestamps select due work", %{commune: commune} do
    due = locator!(commune, "due", ~U[2026-08-20 11:59:59Z])
    future = locator!(commune, "future", ~U[2026-08-20 12:00:01Z])
    stopped = locator!(commune, "stopped", nil)

    assert Enum.map(Ingestion.list_due_locators!(~U[2026-08-20 12:00:00Z]), & &1.id) == [due.id]

    scheduled =
      Ingestion.schedule_locator_fetch!(due, %{
        next_fetch_at: ~U[2026-08-20 18:00:00Z],
        last_checked_at: ~U[2026-08-20 12:00:00Z]
      })

    assert DateTime.compare(scheduled.next_fetch_at, ~U[2026-08-20 18:00:00Z]) == :eq
    assert Ingestion.list_due_locators!(~U[2026-08-20 12:00:00Z]) == []

    assert DateTime.compare(
             Ingestion.get_locator!(future.id).next_fetch_at,
             ~U[2026-08-20 12:00:01Z]
           ) == :eq

    assert Ingestion.get_locator!(stopped.id).next_fetch_at == nil
  end

  test "fixed cron staggers four commune indexes without per-locator entries" do
    crontab =
      Application.fetch_env!(:brussels_wtf, Oban)
      |> Keyword.fetch!(:plugins)
      |> Keyword.fetch!(Oban.Plugins.Cron)
      |> Keyword.fetch!(:crontab)

    poll_entries =
      Enum.filter(crontab, fn {_cron, worker, opts} ->
        worker == BrusselsWtf.Workers.PollCommune and
          not Map.has_key?(opts[:args], :scope)
      end)

    assert Enum.map(poll_entries, fn {_cron, _worker, opts} -> opts[:args][:commune_slug] end) ==
             ~w(ixelles uccle forest city-of-brussels)

    assert Enum.map(poll_entries, &elem(&1, 0)) ==
             ["0 */6 * * *", "15 */6 * * *", "30 */6 * * *", "45 */6 * * *"]

    previous_year_entries =
      Enum.filter(crontab, fn {_cron, worker, opts} ->
        worker == BrusselsWtf.Workers.PollCommune and
          opts[:args][:scope] == "previous-year"
      end)

    assert Enum.map(previous_year_entries, &elem(&1, 0)) ==
             ["5 1 * * *", "20 1 * * *", "35 1 * * *", "50 1 * * *"]

    assert Enum.map(previous_year_entries, fn {_cron, _worker, opts} ->
             opts[:args][:commune_slug]
           end) == ~w(ixelles uccle forest city-of-brussels)

    refute Enum.any?(crontab, fn {_cron, _worker, opts} ->
             Map.has_key?(opts[:args] || %{}, :locator_id)
           end)
  end

  test "health indicators expose stale scheduled polls and recent failures", %{commune: commune} do
    assert Ingestion.poll_health(~U[2026-08-20 12:00:00Z]).stale_commune_ids == [commune.id]

    run =
      Ingestion.start_poll_run!(%{
        commune_id: commune.id,
        started_at: ~U[2026-08-20 00:59:00Z],
        kind: :scheduled,
        requester_id: "system",
        target_type: :commune,
        target_id: commune.id,
        check_key: "health:scheduled",
        status: :queued
      })

    Ingestion.complete_poll_run!(run, %{completed_at: ~U[2026-08-20 01:00:00Z]})

    health = Ingestion.poll_health(~U[2026-08-20 12:00:00Z])
    assert health.stale_commune_count == 0
    assert health.repeated_failure_count == 0
  end

  test "a fixed cron request establishes its configured commune and durable run" do
    assert :ok =
             perform_job(BrusselsWtf.Workers.PollCommune, %{
               commune_slug: "uccle",
               kind: "scheduled"
             })

    commune = Ingestion.get_commune_by_slug!("uccle")
    assert commune.name == "Uccle"

    assert [
             %{
               commune_id: commune_id,
               kind: :scheduled,
               requester_id: "system",
               target_type: :commune,
               status: :queued
             }
           ] = Ingestion.list_poll_runs!()

    assert commune_id == commune.id
  end

  defp locator!(commune, suffix, next_fetch_at) do
    Ingestion.upsert_locator!(%{
      commune_id: commune.id,
      url: "https://example.test/#{suffix}.pdf",
      parent_index_url: commune.index_url,
      meeting_identifier: suffix,
      scheduled_on: ~D[2026-08-30],
      role: :agenda,
      language: :fr,
      discovered_at: ~U[2026-08-20 10:00:00Z],
      next_fetch_at: next_fetch_at
    })
  end
end
