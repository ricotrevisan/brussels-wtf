defmodule BrusselsWtf.ProcessRoleTest do
  use BrusselsWtf.DataCase, async: false

  alias BrusselsWtf.{ProcessRole, Readiness.Monitor}

  defmodule ControlledDependencies do
    def check do
      test = Application.fetch_env!(:brussels_wtf, __MODULE__)
      send(test, {:dependencies_started, self()})

      receive do
        {:dependencies, result} -> result
      end
    end
  end

  setup tags do
    previous = Application.get_env(:brussels_wtf, :process_role)
    Application.put_env(:brussels_wtf, :process_role, :ocr)
    Application.put_env(:brussels_wtf, ControlledDependencies, self())

    on_exit(fn ->
      if previous do
        Application.put_env(:brussels_wtf, :process_role, previous)
      else
        Application.delete_env(:brussels_wtf, :process_role)
      end

      Application.delete_env(:brussels_wtf, ControlledDependencies)
    end)

    clock = start_supervised!({Agent, fn -> 0 end})

    monitor =
      start_supervised!(
        {Monitor,
         name: nil,
         checks: ControlledDependencies,
         interval: Map.get(tags, :monitor_interval, :timer.hours(1)),
         timeout: 1_000,
         now: fn -> Agent.get(clock, & &1) end}
      )

    assert_receive {:dependencies_started, probe}

    %{monitor: monitor, probe: probe, clock: clock}
  end

  test "dependency readiness alone cannot make an absent OCR consumer ready", context do
    send(context.probe, {:dependencies, :ok})
    assert_eventually(fn -> Monitor.status(context.monitor) == :ok end)

    refute ProcessRole.ocr_ready?(monitor: context.monitor, oban: __MODULE__)
  end

  test "an unresponsive readiness cache fails within the probe budget", context do
    :ok = :sys.suspend(context.monitor)
    on_exit(fn -> if Process.alive?(context.monitor), do: :sys.resume(context.monitor) end)

    started = System.monotonic_time(:millisecond)
    refute ProcessRole.ocr_ready?(monitor: context.monitor, oban: __MODULE__)
    assert System.monotonic_time(:millisecond) - started < 1_500
    :ok = :sys.resume(context.monitor)
  end

  test "only a ready OCR role with an active concurrency-one consumer passes", context do
    start_ocr()
    refute ready?(context)

    send(context.probe, {:dependencies, :ok})
    assert_eventually(fn -> ready?(context) end)

    # Health reads must not start dependency validation or enqueue work.
    assert ready?(context)
    assert ready?(context)
    refute_receive {:dependencies_started, _}
    assert Oban.check_queue(__MODULE__, queue: :ocr).running == []

    Application.put_env(:brussels_wtf, :process_role, :app)
    refute ready?(context)
    Application.delete_env(:brussels_wtf, :process_role)
    refute ready?(context)
  end

  test "paused, mis-sized, and stopped OCR queues are not ready", context do
    start_ocr()
    send(context.probe, {:dependencies, :ok})
    assert_eventually(fn -> ready?(context) end)

    :ok = Oban.pause_queue(__MODULE__, queue: :ocr, local_only: true)
    assert_eventually(fn -> Oban.check_queue(__MODULE__, queue: :ocr).paused end)
    refute ready?(context)

    :ok = Oban.resume_queue(__MODULE__, queue: :ocr, local_only: true)
    assert_eventually(fn -> ready?(context) end)

    :ok = Oban.scale_queue(__MODULE__, queue: :ocr, limit: 2, local_only: true)
    assert_eventually(fn -> Oban.check_queue(__MODULE__, queue: :ocr).limit == 2 end)
    refute ready?(context)

    :ok = Oban.stop_queue(__MODULE__, queue: :ocr, local_only: true)
    assert_eventually(fn -> Oban.check_queue(__MODULE__, queue: :ocr) == nil end)
    refute ready?(context)
  end

  test "stale dependency readiness fails despite a live OCR consumer", context do
    start_ocr()
    send(context.probe, {:dependencies, :ok})
    assert_eventually(fn -> ready?(context) end)

    Agent.update(context.clock, fn _ -> 90_001 end)
    refute ready?(context)
    assert Oban.check_queue(__MODULE__, queue: :ocr).limit == 1
  end

  @tag monitor_interval: 10
  test "failed dependency refresh removes readiness from a live consumer", context do
    start_ocr()
    send(context.probe, {:dependencies, :ok})
    assert_eventually(fn -> ready?(context) end)

    assert_receive {:dependencies_started, refresh}
    send(refresh, {:dependencies, {:error, :archive_unavailable}})
    assert_eventually(fn -> Monitor.status(context.monitor) != :ok end)
    refute ready?(context)
  end

  @tag monitor_interval: 10
  test "a crashed dependency refresh cannot retain readiness", context do
    start_ocr()
    send(context.probe, {:dependencies, :ok})
    assert_eventually(fn -> ready?(context) end)

    assert_receive {:dependencies_started, refresh}
    Process.exit(refresh, :kill)
    assert_eventually(fn -> Monitor.status(context.monitor) != :ok end)
    refute ready?(context)
  end

  test "a stopped readiness monitor fails closed", context do
    start_ocr()
    send(context.probe, {:dependencies, :ok})
    assert_eventually(fn -> ready?(context) end)

    stop_supervised!(Monitor)
    refute ready?(context)
  end

  test "app and OCR roles cannot consume each other's work" do
    base = Application.fetch_env!(:brussels_wtf, Oban)
    app = BrusselsWtf.ProcessRole.oban(:app, base)
    ocr = BrusselsWtf.ProcessRole.oban(:ocr, base)

    refute Keyword.has_key?(app[:queues], :ocr)
    assert app[:queues][:corpus] == 1
    assert app[:plugins] != false
    assert ocr[:queues] == [ocr: 1]
    assert ocr[:plugins] == false

    assert BrusselsWtf.Application.oban_config(:app) == app
    assert BrusselsWtf.Application.oban_config(:ocr) == ocr
    assert Application.fetch_env!(:brussels_wtf, :automatic_transcription) == false
  end

  defp start_ocr do
    start_supervised!(
      {Oban,
       name: __MODULE__,
       repo: BrusselsWtf.Repo,
       queues: [ocr: 1],
       plugins: false,
       testing: :disabled,
       peer: Oban.Peers.Isolated,
       notifier: Oban.Notifiers.Isolated}
    )
  end

  defp ready?(context), do: ProcessRole.ocr_ready?(monitor: context.monitor, oban: __MODULE__)

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end
end
