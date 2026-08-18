defmodule BrusselsWtf.Readiness.MonitorTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Readiness.Monitor

  defmodule BlockingProbe do
    def check do
      test = Application.fetch_env!(:brussels_wtf, __MODULE__)
      send(test, {:probe_started, self()})

      receive do
        {:finish_probe, result} -> result
      end
    end
  end

  defmodule FailingProbe do
    def check, do: {:error, {:contains_secret, "private-value"}}
  end

  setup do
    Application.put_env(:brussels_wtf, BlockingProbe, self())
    on_exit(fn -> Application.delete_env(:brussels_wtf, BlockingProbe) end)
  end

  test "starts not ready and caches a successful dependency probe" do
    {:ok, monitor} =
      start_supervised(
        {Monitor,
         name: nil,
         checks: BlockingProbe,
         interval: :timer.hours(1),
         stale_after: :timer.hours(2),
         timeout: 1_000}
      )

    assert_receive {:probe_started, probe}
    assert {:error, :not_ready} = Monitor.status(monitor)

    send(probe, {:finish_probe, :ok})
    assert_eventually(fn -> Monitor.status(monitor) == :ok end)
  end

  test "stores only a sanitized failure state" do
    {:ok, monitor} =
      start_supervised(
        {Monitor,
         name: nil,
         checks: FailingProbe,
         interval: :timer.hours(1),
         stale_after: :timer.hours(2),
         timeout: 1_000}
      )

    assert_eventually(fn -> Monitor.status(monitor) == {:error, :not_ready} end)
  end

  test "becomes not ready when the dependency result is stale" do
    {:ok, clock} = Agent.start_link(fn -> 1_000 end)

    {:ok, monitor} =
      start_supervised(
        {Monitor,
         name: nil,
         checks: BlockingProbe,
         interval: :timer.hours(1),
         stale_after: 20,
         timeout: 1_000,
         now: fn -> Agent.get(clock, & &1) end}
      )

    assert_receive {:probe_started, probe}
    send(probe, {:finish_probe, :ok})
    assert_eventually(fn -> Monitor.status(monitor) == :ok end)

    Agent.update(clock, &(&1 + 21))
    assert Monitor.status(monitor) == {:error, :not_ready}
  end

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
