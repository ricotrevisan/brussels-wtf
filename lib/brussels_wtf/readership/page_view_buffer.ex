defmodule BrusselsWtf.Readership.PageViewBuffer do
  @moduledoc """
  Holds page view totals in memory and writes them in batches.

  Requests only send a cast, so they never wait on or fail with the database.
  A failed write keeps its count for the next flush; pending keys are bounded
  and a restart loses at most one flush interval, which a daily reader total
  tolerates.
  """

  use GenServer

  require Logger

  @flush_interval :timer.seconds(30)
  @max_pending 10_000

  @doc "Records one view. Never raises, including when the buffer is not running."
  def record(key), do: GenServer.cast(__MODULE__, {:record, key})

  @doc "Writes pending totals now."
  def flush, do: GenServer.call(__MODULE__, :flush, :timer.seconds(30))

  def pending_size, do: GenServer.call(__MODULE__, :pending_size)

  @doc """
  A supervisor that can give up without affecting its parent.

  It is `:temporary`, so a persistently crashing buffer stops the counting and
  cannot use up the application's restart budget and take public pages down.
  """
  def isolated_child_spec(opts \\ []) do
    %{
      id: __MODULE__.Supervisor,
      type: :supervisor,
      restart: :temporary,
      start:
        {Supervisor, :start_link,
         [[{__MODULE__, opts}], [strategy: :one_for_one, max_restarts: 5, max_seconds: 60]]}
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      pending: %{},
      interval: Keyword.get(opts, :flush_interval, @flush_interval),
      max_pending: Keyword.get(opts, :max_pending, @max_pending),
      write: Keyword.get(opts, :write, &BrusselsWtf.Readership.record_page_views/2)
    }

    schedule(state.interval)
    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:record, key}, %{pending: pending, max_pending: max} = state) do
    if is_map_key(pending, key) or map_size(pending) < max do
      {:noreply, %{state | pending: Map.update(pending, key, 1, &(&1 + 1))}}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    {result, state} = write_pending(state)
    {:reply, result, state}
  end

  def handle_call(:pending_size, _from, state), do: {:reply, map_size(state.pending), state}

  @impl GenServer
  def handle_info(:flush, state) do
    {_result, state} = write_pending(state)
    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    write_pending(state)
    :ok
  end

  defp write_pending(state) do
    failed =
      Map.filter(state.pending, fn {key, count} ->
        safe_write(state.write, key, count) != :ok
      end)

    case map_size(failed) do
      0 ->
        {:ok, %{state | pending: failed}}

      size ->
        # Only a count: keys hold reader-supplied referrer hosts.
        Logger.warning("page view counts not written; will retry", pending: size)
        {{:error, :write_failed}, %{state | pending: failed}}
    end
  end

  defp safe_write(write, key, count) do
    write.(key, count)
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp schedule(:infinity), do: :ok
  defp schedule(interval), do: Process.send_after(self(), :flush, interval)
end
