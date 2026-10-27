defmodule BrusselsWtf.Workers.OcrLargeSource do
  @moduledoc "Isolated held OCR recovery transport; database claims own execution identity."
  use Oban.Worker, queue: :ocr, max_attempts: 3
  @impl true
  def timeout(_job), do: BrusselsWtf.Ingestion.LargePdfOcrExecution.execution_budget().worker_ms
  @impl true
  def perform(%Oban.Job{args: %{"processing_run_id" => id}, attempt: attempt}) do
    # Since Oban 2.24 a snooze rolls back `attempt`, so contention never
    # consumes a genuine admission failure or a quota-backed page claim.
    case BrusselsWtf.Ingestion.LargePdfOcrRecovery.execute(id, attempt) do
      {:error, :ocr_workspace_busy} -> {:snooze, 30}
      result -> result
    end
  end
end
