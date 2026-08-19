defmodule BrusselsWtf.Workers.ExtractSource do
  @moduledoc false

  use Oban.Worker,
    queue: :extract,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  @impl true
  def perform(%Oban.Job{args: %{"processing_run_id" => processing_run_id}, attempt: attempt}) do
    BrusselsWtf.Ingestion.Pipeline.retry_extraction(processing_run_id, attempt)
  end

  def perform(%Oban.Job{
        args: %{"source_version_id" => source_version_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case BrusselsWtf.Ingestion.Pipeline.extract(source_version_id, attempt) do
      :ok ->
        :ok

      {:error, reason} = error ->
        classification = BrusselsWtf.Ingestion.ProcessingFailure.classify(reason)

        if BrusselsWtf.Ingestion.ProcessingFailure.deterministic?(classification) or
             attempt >= max_attempts do
          BrusselsWtf.Ingestion.ExtractionReview.open_for_version(
            source_version_id,
            BrusselsWtf.Ingestion.ProcessingFailure.terminal(classification)
          )

          :ok
        else
          error
        end
    end
  end
end
