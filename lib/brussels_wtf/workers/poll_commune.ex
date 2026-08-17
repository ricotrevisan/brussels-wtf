defmodule BrusselsWtf.Workers.PollCommune do
  @moduledoc false
  use Oban.Worker, queue: :poll, max_attempts: 3

  @impl true
  def perform(%Oban.Job{args: %{"commune_id" => commune_id}}) do
    BrusselsWtf.Ingestion.Pipeline.discover_and_enqueue(commune_id)
  end
end
