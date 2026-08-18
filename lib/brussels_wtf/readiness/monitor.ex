defmodule BrusselsWtf.Readiness.Monitor do
  @moduledoc """
  Runs bounded dependency probes away from HTTP requests and exposes only a
  cached, expiring readiness result.
  """

  use GenServer

  @task_supervisor BrusselsWtf.Readiness.TaskSupervisor

  def start_link(options) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec status(GenServer.server()) :: :ok | {:error, :not_ready}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(options) do
    config = Application.get_env(:brussels_wtf, __MODULE__, [])

    state = %{
      checks: Keyword.get(options, :checks, Keyword.get(config, :checks, BrusselsWtf.Readiness)),
      interval: Keyword.get(options, :interval, Keyword.get(config, :interval, 30_000)),
      stale_after: Keyword.get(options, :stale_after, Keyword.get(config, :stale_after, 90_000)),
      timeout: Keyword.get(options, :timeout, Keyword.get(config, :timeout, 300_000)),
      now: Keyword.get(options, :now, fn -> System.monotonic_time(:millisecond) end),
      task: nil,
      timeout_ref: nil,
      ready?: false,
      last_success: nil
    }

    send(self(), :check)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    ready? =
      state.ready? and is_integer(state.last_success) and
        state.now.() - state.last_success <= state.stale_after

    {:reply, if(ready?, do: :ok, else: {:error, :not_ready}), state}
  end

  @impl true
  def handle_info(:check, %{task: nil} = state) do
    task = Task.Supervisor.async_nolink(@task_supervisor, state.checks, :check, [])
    timeout_ref = Process.send_after(self(), {:probe_timeout, task.ref}, state.timeout)
    {:noreply, %{state | task: task, timeout_ref: timeout_ref}}
  end

  def handle_info(:check, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(state.timeout_ref)
    {:noreply, finish_probe(state, result == :ok)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %{ref: ref}} = state) do
    Process.cancel_timer(state.timeout_ref)
    {:noreply, finish_probe(state, false)}
  end

  def handle_info({:probe_timeout, ref}, %{task: %{ref: ref} = task} = state) do
    Task.Supervisor.terminate_child(@task_supervisor, task.pid)
    {:noreply, finish_probe(state, false)}
  end

  def handle_info({:probe_timeout, _old_ref}, state), do: {:noreply, state}
  def handle_info({:DOWN, _old_ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp finish_probe(state, true) do
    schedule_check(state.interval)

    %{
      state
      | task: nil,
        timeout_ref: nil,
        ready?: true,
        last_success: state.now.()
    }
  end

  defp finish_probe(state, false) do
    schedule_check(state.interval)
    %{state | task: nil, timeout_ref: nil, ready?: false}
  end

  defp schedule_check(interval), do: Process.send_after(self(), :check, interval)
end
