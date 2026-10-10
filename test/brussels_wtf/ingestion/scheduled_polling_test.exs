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
    assert commune.id in Ingestion.poll_health(~U[2026-08-20 12:00:00Z]).stale_commune_ids

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
    refute commune.id in health.stale_commune_ids
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

  test "fixed cron schedules a commune once its explicit adapter is implemented" do
    assert :ok =
             perform_job(BrusselsWtf.Workers.PollCommune, %{
               commune_slug: "uccle",
               kind: "scheduled"
             })

    assert [%{kind: :scheduled, target_type: :commune, status: :queued}] =
             Ingestion.list_poll_runs!()
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
    standing_schedule = Ingestion.get_locator!(project.id).next_fetch_at

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

    assert Ingestion.get_locator!(project.id).next_fetch_at == standing_schedule

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

  test "poll-now initializes policy state only for genuinely new active locators", %{
    commune: commune
  } do
    index = File.read!("test/support/fixtures/ixelles/proposal/index.html")
    BrusselsWtf.HTTP.Stub.put(commune.index_url, %{status: 200, body: index})

    manual =
      Ingestion.request_poll_now!(%{type: :commune, id: commune.id},
        actor: %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}
      )

    assert :ok =
             BrusselsWtf.Ingestion.Pipeline.discover_and_enqueue(
               commune.id,
               manual.id,
               manual.check_key,
               1
             )

    assert commune.id
           |> Ingestion.list_document_locators!()
           |> Enum.reject(&(&1.role == :recording))
           |> Enum.all?(&match?(%DateTime{}, &1.next_fetch_at))
  end

  test "scheduled current indexes dispatch known due nested work for 200 and 304", %{
    commune: commune
  } do
    index = File.read!("test/support/fixtures/ixelles/proposal/index.html")
    BrusselsWtf.HTTP.Stub.put(commune.index_url, %{status: 200, body: index})
    nested = nested_locator!(commune, "nested", ~U[2026-08-20 11:59:59Z])
    future = nested_locator!(commune, "future-nested", ~U[2026-08-20 12:00:01Z])
    stopped = nested_locator!(commune, "stopped-nested", nil)
    disappeared = nested_locator!(commune, "gone-nested", ~U[2026-08-20 11:59:59Z])

    unsupported =
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: "https://example.test/recording",
        parent_index_url: "https://example.test/old-item",
        meeting_identifier: "old",
        role: :recording,
        language: :fr,
        discovered_at: ~U[2026-08-20 10:00:00Z],
        next_fetch_at: ~U[2026-08-20 11:59:59Z]
      })

    other_commune =
      Ingestion.create_commune!(%{
        slug: "forest",
        name: "Forest",
        index_url: "https://example.test/other-index"
      })

    other_due = nested_locator!(other_commune, "other-commune", ~U[2026-08-20 11:59:59Z])

    for status <- [200, 304] do
      run = Ingestion.request_scheduled_poll!(commune.slug)

      Ingestion.record_observation!(%{
        source_locator_id: disappeared.id,
        poll_run_id: run.id,
        check_key: "gone:#{run.id}",
        observed_at: ~U[2026-08-20 12:00:00Z],
        status: :disappeared,
        final_url: disappeared.url
      })

      BrusselsWtf.HTTP.Stub.put(commune.index_url, %{status: status, body: index})

      assert :ok =
               BrusselsWtf.Ingestion.Pipeline.discover_and_enqueue(
                 commune.id,
                 run.id,
                 run.check_key
               )

      assert :ok =
               BrusselsWtf.Ingestion.Pipeline.discover_and_enqueue(
                 commune.id,
                 run.id,
                 run.check_key
               )

      jobs =
        all_enqueued(worker: BrusselsWtf.Workers.FetchLocator)
        |> Enum.filter(&(&1.args["poll_run_id"] == run.id))

      assert Enum.count(jobs, &(&1.args["locator_id"] == nested.id)) == 1

      for excluded <- [future, stopped, disappeared, unsupported, other_due] do
        refute Enum.any?(jobs, &(&1.args["locator_id"] == excluded.id))
      end
    end
  end

  test "scheduled nested dispatch and parent replay share one fetch identity", %{commune: commune} do
    index = File.read!("test/support/fixtures/ixelles/proposal/index.html")
    BrusselsWtf.HTTP.Stub.put(commune.index_url, %{status: 200, body: index})
    nested = nested_locator!(commune, "deduplicated", ~U[2026-08-20 11:59:59Z])
    future = nested_locator!(commune, "replay-future", ~U[2026-08-20 12:00:01Z])
    stopped = nested_locator!(commune, "replay-stopped", nil)

    parent =
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: nested.parent_index_url,
        parent_index_url: "https://example.test/old-listing",
        meeting_identifier: "old",
        role: :item_listing,
        language: :fr,
        discovered_at: ~U[2026-08-20 10:00:00Z],
        next_fetch_at: ~U[2026-08-20 11:59:59Z]
      })

    source =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: parent.url,
        role: :item_listing,
        original_language: :fr
      })

    archived = BrusselsWtf.Archive.store("listing") |> elem(1)

    version =
      Ingestion.upsert_source_version!(%{
        source_record_id: source.id,
        sha256: archived.sha256,
        object_key: archived.object_key,
        byte_size: 7,
        media_type: "text/html",
        first_retrieved_at: ~U[2026-08-20 11:00:00Z]
      })

    run = Ingestion.request_scheduled_poll!(commune.slug)

    Ingestion.record_observation!(%{
      source_locator_id: parent.id,
      source_version_id: version.id,
      poll_run_id: run.id,
      check_key: "parent-prior",
      observed_at: ~U[2026-08-20 11:00:00Z],
      status: :success,
      final_url: parent.url
    })

    assert :ok =
             BrusselsWtf.Ingestion.Pipeline.discover_and_enqueue(
               commune.id,
               run.id,
               run.check_key <> ":index:attempt:1"
             )

    BrusselsWtf.HTTP.Stub.put(parent.url, %{status: 304})

    assert :ok =
             perform_job(BrusselsWtf.Workers.FetchLocator, %{
               locator_id: parent.id,
               poll_run_id: run.id,
               check_key: run.check_key,
               attempt: 1
             })

    jobs =
      all_enqueued(worker: BrusselsWtf.Workers.FetchLocator)
      |> Enum.filter(&(&1.args["poll_run_id"] == run.id))

    assert Enum.count(jobs, &(&1.args["locator_id"] == nested.id)) == 1

    for excluded <- [future, stopped] do
      refute Enum.any?(jobs, &(&1.args["locator_id"] == excluded.id))
    end
  end

  test "scheduled listing rediscovery reactivates only disappeared children" do
    commune =
      Ingestion.create_commune!(%{
        slug: "city-of-brussels",
        name: "Brussels",
        index_url: "https://example.test/city"
      })

    parent =
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: "https://example.test/item",
        parent_index_url: "https://example.test/meeting",
        meeting_identifier: "2026-08-01",
        scheduled_on: ~D[2026-08-01],
        role: :item_listing,
        item_identifier: "003",
        language: :fr,
        discovered_at: ~U[2026-08-20 10:00:00Z],
        next_fetch_at: ~U[2026-08-20 11:59:59Z]
      })

    child = fn name ->
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: "https://example.test/#{name}.pdf",
        parent_index_url: parent.url,
        meeting_identifier: "2026-08-01",
        scheduled_on: ~D[2026-08-01],
        role: :supporting_document,
        item_identifier: "003",
        language: :fr,
        observed_label: "FR",
        discovered_at: ~U[2026-08-20 10:00:00Z],
        next_fetch_at: nil
      })
    end

    gone = child.("gone")
    stopped = child.("stopped")
    run = Ingestion.request_scheduled_poll!(commune.slug)

    Ingestion.record_observation!(%{
      source_locator_id: gone.id,
      poll_run_id: run.id,
      check_key: "gone-before",
      observed_at: ~U[2026-08-20 11:00:00Z],
      status: :disappeared,
      final_url: gone.url
    })

    BrusselsWtf.HTTP.Stub.put(parent.url, %{
      status: 200,
      body: ~s(<a href="/gone.pdf">FR</a><a href="/stopped.pdf">FR</a>)
    })

    assert :ok =
             perform_job(BrusselsWtf.Workers.FetchLocator, %{
               locator_id: parent.id,
               poll_run_id: run.id,
               check_key: run.check_key,
               attempt: 1
             })

    assert_enqueued(
      worker: BrusselsWtf.Workers.FetchLocator,
      args: %{locator_id: gone.id, poll_run_id: run.id}
    )

    refute_enqueued(
      worker: BrusselsWtf.Workers.FetchLocator,
      args: %{locator_id: stopped.id, poll_run_id: run.id}
    )
  end

  defp nested_locator!(commune, suffix, next_fetch_at) do
    Ingestion.upsert_locator!(%{
      commune_id: commune.id,
      url: "https://example.test/#{suffix}.pdf",
      parent_index_url: "https://example.test/old-item",
      meeting_identifier: "old",
      scheduled_on: ~D[2026-08-01],
      role: :supporting_document,
      language: :fr,
      discovered_at: ~U[2026-08-20 10:00:00Z],
      next_fetch_at: next_fetch_at
    })
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
