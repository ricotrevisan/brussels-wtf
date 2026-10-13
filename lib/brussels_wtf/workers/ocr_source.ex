defmodule BrusselsWtf.Workers.OCRSource do
  @moduledoc false

  use Oban.Worker,
    queue: :ocr,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  alias BrusselsWtf.Ingestion

  @impl true
  def perform(%Oban.Job{
        args: %{"processing_run_id" => processing_run_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case Ingestion.Pipeline.ocr(processing_run_id, attempt) do
      {:error, :extraction_only} ->
        {:discard, "extraction-only generation cannot enter the ordinary OCR pipeline"}

      :ok ->
        :ok

      {:error, reason} = error ->
        classification = Ingestion.ProcessingFailure.classify(reason)

        if Ingestion.ProcessingFailure.deterministic?(classification) or attempt >= max_attempts do
          run = Ingestion.get_processing_run!(processing_run_id) |> Ash.load!(:source_version)
          terminal = Ingestion.ProcessingFailure.terminal(classification)
          Ingestion.Pipeline.fail_processing_run(run, terminal)
          Ingestion.ExtractionReview.open_for_version(run.source_version.id, terminal, run.id)
          :ok
        else
          Ingestion.Observability.processing_retry(%{
            processing_run_id: processing_run_id,
            classification: classification,
            processor_role: :ocr,
            attempt: attempt
          })

          error
        end
    end
  end
end
