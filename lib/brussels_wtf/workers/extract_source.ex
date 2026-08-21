defmodule BrusselsWtf.Workers.ExtractSource do
  @moduledoc false

  use Oban.Worker,
    queue: :extract,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  @impl true
  def perform(%Oban.Job{
        args: %{"processing_run_id" => processing_run_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case BrusselsWtf.Ingestion.Pipeline.retry_extraction(processing_run_id, attempt) do
      :ok ->
        :ok

      {:error, reason} = error ->
        classification = BrusselsWtf.Ingestion.ProcessingFailure.classify(reason)

        if BrusselsWtf.Ingestion.ProcessingFailure.deterministic?(classification) or
             attempt >= max_attempts do
          run =
            processing_run_id
            |> BrusselsWtf.Ingestion.get_processing_run!()
            |> Ash.load!(:source_version)

          terminal = BrusselsWtf.Ingestion.ProcessingFailure.terminal(classification)
          BrusselsWtf.Ingestion.Pipeline.fail_processing_run(run, terminal)

          BrusselsWtf.Ingestion.ExtractionReview.open_for_version(
            run.source_version.id,
            terminal,
            run.id
          )

          :ok
        else
          BrusselsWtf.Ingestion.Observability.processing_retry(%{
            processing_run_id: processing_run_id,
            classification: classification,
            processor_role: :native_extraction,
            attempt: attempt
          })

          error
        end
    end
  end

  def perform(%Oban.Job{
        args: %{"source_version_id" => source_version_id} = args,
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    generation_kind = if args["generation_kind"] == "backfill", do: :backfill, else: :automatic

    case BrusselsWtf.Ingestion.Pipeline.extract(source_version_id, attempt, generation_kind) do
      :ok ->
        :ok

      {:error, reason} = error ->
        classification = BrusselsWtf.Ingestion.ProcessingFailure.classify(reason)

        if BrusselsWtf.Ingestion.ProcessingFailure.deterministic?(classification) or
             attempt >= max_attempts do
          terminal = BrusselsWtf.Ingestion.ProcessingFailure.terminal(classification)
          run = BrusselsWtf.Ingestion.Pipeline.fail_native_generation(source_version_id, terminal)

          BrusselsWtf.Ingestion.ExtractionReview.open_for_version(
            source_version_id,
            terminal,
            run.id
          )

          :ok
        else
          BrusselsWtf.Ingestion.Observability.processing_retry(%{
            source_version_id: source_version_id,
            processing_run_id: queued_native_run_id(source_version_id),
            classification: classification,
            processor_role: :native_extraction,
            attempt: attempt
          })

          error
        end
    end
  end

  defp queued_native_run_id(source_version_id) do
    source_version_id
    |> BrusselsWtf.Ingestion.get_source_version!()
    |> Ash.load!(:processing_runs)
    |> Map.fetch!(:processing_runs)
    |> Enum.find(&(&1.processor_role == :native_extraction and &1.status == :queued))
    |> then(&if(&1, do: &1.id))
  end
end
