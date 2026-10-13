defmodule BrusselsWtf.Workers.OcrLargeSource do
  @moduledoc "Isolated held OCR recovery transport; database claims own execution identity."
  use Oban.Worker, queue: :ocr, max_attempts: 3
  @impl true
  def timeout(_job), do: BrusselsWtf.Ingestion.LargePdfOcrExecution.execution_budget().worker_ms
  @impl true
  def perform(%Oban.Job{args: %{"processing_run_id" => id}, attempt: attempt} = job) do
    # Oban extends max_attempts for every snooze. Contention must not consume
    # a genuine admission failure or a quota-backed page claim.
    snoozes = max((job.max_attempts || 3) - 3, 0)
    failure_attempt = max(attempt - snoozes, 1)

    case BrusselsWtf.Ingestion.LargePdfOcrRecovery.execute(id, failure_attempt) do
      {:error, :ocr_workspace_busy} -> {:snooze, 30}
      result -> result
    end
  end
end
