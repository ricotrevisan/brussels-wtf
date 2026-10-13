defmodule BrusselsWtf.Workers.ExtractLargeSource do
  @moduledoc "Audited native-only large source recovery; no OCR or downstream jobs."
  use Oban.Worker,
    queue: :extract,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  @impl true
  def perform(%Oban.Job{args: %{"processing_run_id" => id}, attempt: attempt}) do
    BrusselsWtf.Ingestion.LargePdfRecovery.execute(id, attempt)
  end
end
