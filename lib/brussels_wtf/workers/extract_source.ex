defmodule BrusselsWtf.Workers.ExtractSource do
  @moduledoc false
  use Oban.Worker,
    queue: :extract,
    max_attempts: 3,
    unique: [period: :infinity, states: :successful]

  @impl true
  def perform(%Oban.Job{args: %{"source_version_id" => source_version_id}}) do
    BrusselsWtf.Ingestion.Pipeline.extract(source_version_id)
  end
end
