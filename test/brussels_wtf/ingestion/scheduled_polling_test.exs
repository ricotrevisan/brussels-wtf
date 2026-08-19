defmodule BrusselsWtf.Ingestion.ScheduledPollingTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Ingestion

  setup do
    BrusselsWtf.HTTP.Stub.reset()
    BrusselsWtf.Archive.Memory.reset()
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

  test "a fixed cron request creates durable current and previous-year runs", %{
    commune: commune
  } do
    assert :ok =
             perform_job(BrusselsWtf.Workers.PollCommune, %{
               commune_slug: "ixelles",
               kind: "scheduled"
             })

    assert [
             %{
               commune_id: commune_id,
               kind: :scheduled,
               requester_id: "system",
               target_type: :commune,
               scope: :current,
               status: :queued
             }
           ] = Ingestion.list_poll_runs!()

    assert commune_id == commune.id

    assert :ok =
             perform_job(BrusselsWtf.Workers.PollCommune, %{
               commune_slug: "ixelles",
               kind: "scheduled",
               scope: "previous-year"
             })

    assert Enum.any?(Ingestion.list_poll_runs!(), fn run ->
             run.commune_id == commune.id and run.target_type == :index and
               run.scope == :previous_year
           end)
  end

  test "fixed cron skips a commune until its explicit adapter is implemented" do
    assert :ok =
             perform_job(BrusselsWtf.Workers.PollCommune, %{
               commune_slug: "uccle",
               kind: "scheduled"
             })

    assert Ingestion.list_poll_runs!() == []
  end

  test "previous-year and backfill scopes select distinct index work", %{commune: commune} do
    current = File.read!("test/support/fixtures/ixelles/proposal/index.html")
    previous = String.replace(current, "[2026]", "[2025]")
    index = current <> previous

    BrusselsWtf.HTTP.Stub.put(commune.index_url, %{status: 200, body: index})
    previous = Ingestion.request_scheduled_poll!("ixelles", :previous_year)

    assert :ok =
             BrusselsWtf.Ingestion.Pipeline.discover_and_enqueue(
               commune.id,
               previous.id,
               previous.check_key,
               1
             )

    locators = Ingestion.list_document_locators!(commune.id)
    assert MapSet.new(Enum.map(locators, & &1.scheduled_on.year)) == MapSet.new([2025, 2026])

    previous_job_locator_ids =
      all_enqueued(worker: BrusselsWtf.Workers.FetchLocator)
      |> Enum.filter(&(&1.args["poll_run_id"] == previous.id))
      |> Enum.map(& &1.args["locator_id"])
      |> MapSet.new()

    refute MapSet.size(previous_job_locator_ids) == 0

    assert Enum.all?(locators, fn locator ->
             if MapSet.member?(previous_job_locator_ids, locator.id) do
               locator.scheduled_on.year == 2025
             else
               true
             end
           end)

    previous_year_locators =
      Enum.filter(locators, fn locator ->
        locator.scheduled_on.year == 2025 and
          locator.role in [:agenda, :project, :supplement, :addendum, :minutes, :register]
      end)

    Enum.each(previous_year_locators, fn locator ->
      Ingestion.record_observation!(%{
        source_locator_id: locator.id,
        poll_run_id: previous.id,
        check_key: "stopped:#{locator.id}",
        observed_at: ~U[2026-08-20 12:00:00Z],
        status: :unchanged,
        final_url: locator.url
      })

      Ingestion.schedule_locator_fetch!(locator, %{next_fetch_at: nil})
    end)

    stopped_check = Ingestion.request_scheduled_poll!("ixelles", :previous_year)

    assert :ok =
             BrusselsWtf.Ingestion.Pipeline.discover_and_enqueue(
               commune.id,
               stopped_check.id,
               stopped_check.check_key,
               1
             )

    refute Enum.any?(all_enqueued(worker: BrusselsWtf.Workers.FetchLocator), fn job ->
             job.args["poll_run_id"] == stopped_check.id
           end)

    backfill =
      Ingestion.request_backfill!(%{type: :commune, id: commune.id},
        actor: %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}
      )

    assert :ok =
             BrusselsWtf.Ingestion.Pipeline.discover_and_enqueue(
               commune.id,
               backfill.id,
               backfill.check_key,
               1
             )

    assert Ingestion.list_document_locators!(commune.id)
           |> Enum.map(& &1.scheduled_on.year)
           |> MapSet.new() == MapSet.new([2025, 2026])
  end

  test "a scheduled index rediscovery reactivates a disappeared locator", %{commune: commune} do
    index = File.read!("test/support/fixtures/ixelles/proposal/index.html")
    BrusselsWtf.HTTP.Stub.put(commune.index_url, %{status: 200, body: index})

    first =
      Ingestion.request_poll_now!(%{type: :commune, id: commune.id},
        actor: %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}
      )

    assert :ok =
             perform_job(BrusselsWtf.Workers.PollCommune, %{
               commune_id: commune.id,
               poll_run_id: first.id,
               check_key: first.check_key,
               attempt: 1
             })

    project =
      commune.id
      |> Ingestion.list_document_locators!()
      |> Enum.find(&(&1.role == :project and &1.meeting_identifier == "268"))

    missing_project =
      Regex.replace(
        ~r/<a href="\.\.\/uploads\/conseil\/projets\/268\.pdf".*?<\/a> \(2618 Ko\)/s,
        index,
        ""
      )

    BrusselsWtf.HTTP.Stub.put(commune.index_url, %{status: 200, body: missing_project})

    second =
      Ingestion.request_poll_now!(%{type: :commune, id: commune.id},
        actor: %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}
      )

    assert :ok =
             perform_job(BrusselsWtf.Workers.PollCommune, %{
               commune_id: commune.id,
               poll_run_id: second.id,
               check_key: second.check_key,
               attempt: 1
             })

    assert List.last(Ingestion.list_observations!(project.id)).status == :disappeared

    BrusselsWtf.HTTP.Stub.put(commune.index_url, %{status: 200, body: index})

    manual =
      Ingestion.request_poll_now!(%{type: :commune, id: commune.id},
        actor: %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}
      )

    assert :ok =
             perform_job(BrusselsWtf.Workers.PollCommune, %{
               commune_id: commune.id,
               poll_run_id: manual.id,
               check_key: manual.check_key,
               attempt: 1
             })

    assert is_nil(Ingestion.get_locator!(project.id).next_fetch_at)

    scheduled = Ingestion.request_scheduled_poll!("ixelles")

    assert :ok =
             perform_job(BrusselsWtf.Workers.PollCommune, %{
               commune_id: commune.id,
               poll_run_id: scheduled.id,
               check_key: scheduled.check_key,
               attempt: 1
             })

    assert_enqueued(
      worker: BrusselsWtf.Workers.FetchLocator,
      args: %{locator_id: project.id, poll_run_id: scheduled.id}
    )
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
