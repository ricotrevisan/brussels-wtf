defmodule BrusselsWtf.ProcessRole do
  @moduledoc "Queue isolation contract for lightweight and OCR release roles."

  @doc "Checks the running OCR role without refreshing dependency probes or changing queues."
  @spec ocr_ready?(keyword()) :: boolean()
  def ocr_ready?(options \\ []) do
    if Application.get_env(:brussels_wtf, :process_role) == :ocr do
      task =
        Task.Supervisor.async_nolink(BrusselsWtf.Readiness.TaskSupervisor, fn ->
          ocr_dependencies_ready?(options)
        end)

      result = Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill)
      result == {:ok, true}
    else
      false
    end
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp ocr_dependencies_ready?(options) do
    monitor = Keyword.get(options, :monitor, BrusselsWtf.Readiness.Monitor)
    oban = Keyword.get(options, :oban, Oban)

    BrusselsWtf.Readiness.Monitor.status(monitor) == :ok and
      match?(%{queue: "ocr", paused: false, limit: 1}, Oban.check_queue(oban, queue: :ocr))
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  def oban(:app, base) do
    base
    |> Keyword.put(:queues,
      poll: 1,
      fetch: 1,
      extract: 1,
      normalize: 1,
      enrich: 1,
      publish: 1,
      corpus: 1,
      maintenance: 1
    )
  end

  def oban(:ocr, base) do
    base
    |> Keyword.put(:plugins, false)
    |> Keyword.put(:queues, ocr: 1)
  end
end
