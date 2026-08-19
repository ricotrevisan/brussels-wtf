defmodule BrusselsWtf.Ingestion.ExtractionReview do
  @moduledoc "Converges terminal extraction failures on one actionable private review case."

  alias BrusselsWtf.Ingestion

  def open_for_version(source_version_id, classification, processing_run_id \\ nil) do
    version = source_version_id |> Ingestion.get_source_version!() |> Ash.load!(:source_record)
    generation = processing_run_id

    review_case =
      BrusselsWtf.Review.open_review_case!(%{
        kind: :extraction,
        commune_id: version.source_record.commune_id,
        affected_record_id: version.id,
        affected_record_type: "source_version",
        source_record_id: version.source_record.id,
        source_version_id: version.id,
        processing_generation: "extraction:#{generation}",
        urgency: :high,
        summary: summary(classification),
        diagnostics: %{"classification" => Atom.to_string(classification)},
        related_evidence: %{"processing_run_id" => processing_run_id}
      })

    Ingestion.Observability.review_case_created(%{
      source_version_id: version.id,
      processing_run_id: processing_run_id,
      review_case_id: review_case.id,
      commune_id: version.source_record.commune_id,
      classification: classification
    })

    review_case
  end

  defp summary(:repeated_quality_failure), do: "OCR fallback quality failed and requires review"
  defp summary(:unsupported_media), do: "Source media is unsupported and requires review"
  defp summary(:invalid_content), do: "Source content is invalid and requires review"

  defp summary(:corruption),
    do: "Archived source failed checksum verification and requires review"

  defp summary(:resource_limit), do: "PDF processing exceeded a calibrated resource limit"
  defp summary(:processor_unavailable), do: "The configured PDF processor is unavailable"
  defp summary(:processor_failure), do: "The PDF processor failed repeatedly"
  defp summary(_classification), do: "PDF processing failed repeatedly and requires review"
end
