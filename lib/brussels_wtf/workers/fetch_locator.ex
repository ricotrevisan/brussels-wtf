defmodule BrusselsWtf.Workers.FetchLocator do
  @moduledoc false
  use Oban.Worker, queue: :fetch, max_attempts: 3

  @impl true
  def perform(%Oban.Job{args: %{"locator_id" => locator_id, "poll_run_id" => poll_run_id}}) do
    BrusselsWtf.Ingestion.Pipeline.retrieve(locator_id, poll_run_id)
  end
end
