defmodule BrusselsWtf.Ingestion.NormalizationReview do
  @moduledoc "Converges unavailable automatic normalization on one actionable private review case."

  alias BrusselsWtf.Ingestion

  def open_for_run(run, citation_url),
    do: open_for_run(run, citation_url, :processor_unavailable, %{})

  def open_for_run(run, citation_url, classification, normalized_content)
      when classification in [
             :processor_unavailable,
             :normalization_ambiguity,
             :processor_failure
           ] and
             is_map(normalized_content) do
    version = run.source_version
    source_record = version.source_record

    review_case =
      BrusselsWtf.Review.open_review_case!(%{
        kind: :normalization,
        commune_id: source_record.commune_id,
        affected_record_id: version.id,
        affected_record_type: "source_version",
        source_record_id: source_record.id,
        source_version_id: version.id,
        processing_generation: "normalization:#{run.id}",
        urgency: :high,
        summary: summary(classification),
        normalized_content: normalized_content,
        diagnostics: %{
          "classification" => Atom.to_string(classification),
          "detail" => detail(classification)
        },
        related_evidence: %{
          "citation_url" => citation_url,
          "processing_run_id" => run.id
        }
      })

    Ingestion.Observability.review_case_created(%{
      source_version_id: version.id,
      processing_run_id: run.id,
      review_case_id: review_case.id,
      commune_id: source_record.commune_id,
      classification: classification
    })

    review_case
  end

  defp summary(:processor_unavailable),
    do: "Automatic normalization is unavailable and requires review"

  defp summary(:normalization_ambiguity),
    do: "Normalized item continuity is ambiguous and requires review"

  defp summary(:processor_failure),
    do: "Automatic normalization failed repeatedly and requires review"

  defp detail(:processor_unavailable), do: "No production normalizer is configured"

  defp detail(:normalization_ambiguity),
    do: "The processor returned competing normalized candidates"

  defp detail(:processor_failure), do: "The normalizer failed after three attempts"
end
