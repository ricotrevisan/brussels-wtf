defmodule BrusselsWtf.Workers.NormalizeSource do
  @moduledoc false
  use Oban.Worker,
    queue: :normalize,
    max_attempts: 3,
    unique: [period: :infinity, states: :successful]

  @impl true
  def perform(%Oban.Job{args: %{"processing_run_id" => run_id, "locator_url" => url}}) do
    BrusselsWtf.Ingestion.Pipeline.normalize(run_id, url)
  end
end
