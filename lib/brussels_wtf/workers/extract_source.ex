defmodule BrusselsWtf.Workers.ExtractSource do
  @moduledoc false
  use Oban.Worker,
    queue: :extract,
    max_attempts: 3,
    unique: [period: :infinity, states: :successful]

  @impl true
  def perform(%Oban.Job{args: %{"processing_run_id" => processing_run_id}}) do
    BrusselsWtf.Ingestion.Pipeline.retry_extraction(processing_run_id)
  end

  def perform(%Oban.Job{args: %{"source_version_id" => source_version_id}}) do
    BrusselsWtf.Ingestion.Pipeline.extract(source_version_id)
  end
end
