defmodule BrusselsWtf.Workers.ExtractSource do
  @moduledoc false

  use Oban.Worker,
    queue: :extract,
    max_attempts: 3,
    unique: [period: :infinity, states: :successful]

  alias BrusselsWtf.Ingestion

  @impl true
  def perform(%Oban.Job{args: %{"processing_run_id" => processing_run_id}}) do
    BrusselsWtf.Ingestion.Pipeline.retry_extraction(processing_run_id)
  end

  def perform(%Oban.Job{
        args: %{"source_version_id" => source_version_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case BrusselsWtf.Ingestion.Pipeline.extract(source_version_id) do
      :ok ->
        :ok

      {:error, reason} = error ->
        classification = classify(reason)

        if deterministic?(classification) or attempt >= max_attempts do
          open_terminal_case(source_version_id, terminal_classification(classification))
          :ok
        else
          error
        end
    end
  end

  defp open_terminal_case(source_version_id, classification) do
    version =
      source_version_id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:source_record)

    review_case =
      BrusselsWtf.Review.open_review_case!(%{
        kind: :extraction,
        commune_id: version.source_record.commune_id,
        affected_record_id: version.id,
        affected_record_type: "source_version",
        source_record_id: version.source_record.id,
        source_version_id: version.id,
        processing_generation: "extraction:#{version.id}:#{classification}",
        urgency: :high,
        summary: summary(classification),
        diagnostics: %{"classification" => Atom.to_string(classification)}
      })

    BrusselsWtf.Ingestion.Observability.review_case_created(%{
      source_version_id: version.id,
      review_case_id: review_case.id,
      commune_id: version.source_record.commune_id,
      classification: classification
    })
  end

  defp classify(:repeated_quality_failure), do: :repeated_quality_failure
  defp classify({:quality_failure, _details}), do: :repeated_quality_failure
  defp classify(:unsupported_media), do: :unsupported_media
  defp classify({:unsupported_media, _details}), do: :unsupported_media
  defp classify(:invalid_content), do: :invalid_content
  defp classify({:invalid_content, _details}), do: :invalid_content
  defp classify({:archived_hash_mismatch, _expected, _actual}), do: :corruption
  defp classify(_reason), do: :processing_failure

  defp deterministic?(classification),
    do:
      classification in [
        :repeated_quality_failure,
        :unsupported_media,
        :invalid_content,
        :corruption
      ]

  defp terminal_classification(:processing_failure), do: :repeated_quality_failure
  defp terminal_classification(classification), do: classification

  defp summary(:repeated_quality_failure),
    do: "Native extraction quality failed repeatedly and requires review"

  defp summary(:unsupported_media), do: "Source media is unsupported and requires review"
  defp summary(:invalid_content), do: "Source content is invalid and requires review"

  defp summary(:corruption),
    do: "Archived source failed checksum verification and requires review"
end
