defmodule BrusselsWtf.Workers.NormalizeSource do
  @moduledoc false
  @max_attempts 3

  use Oban.Worker,
    queue: :normalize,
    max_attempts: @max_attempts,
    unique: [period: :infinity, states: :successful]

  @impl true
  def perform(%Oban.Job{
        args: %{"processing_run_id" => run_id, "locator_url" => url},
        attempt: attempt
      }) do
    BrusselsWtf.Ingestion.Pipeline.normalize(run_id, url, attempt, @max_attempts)
  end
end
