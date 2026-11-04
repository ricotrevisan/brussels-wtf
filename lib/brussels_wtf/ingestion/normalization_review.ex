defmodule BrusselsWtf.Ingestion.NormalizationReview do
  @moduledoc "Converges unavailable automatic normalization on one actionable private review case."

  alias BrusselsWtf.Ingestion

  def open_contract_change(run_id, queued_contract, current_contract) do
    run = Ingestion.get_processing_run!(run_id) |> Ash.load!(source_version: :source_record)
    version = run.source_version

    BrusselsWtf.Review.open_review_case!(%{
      kind: :normalization,
      commune_id: version.source_record.commune_id,
      affected_record_id: version.id,
      affected_record_type: "source_version",
      source_record_id: version.source_record_id,
      source_version_id: version.id,
      processing_generation: "normalization-contract:#{run.id}:#{queued_contract}",
      urgency: :normal,
      summary: "Queued normalization contract changed; retry with the current release",
      diagnostics: %{
        "classification" => "processor_contract_changed",
        "queued_contract" => queued_contract,
        "current_contract" => current_contract
      },
      related_evidence: %{
        "processing_run_id" => run.id,
        "citation_url" => version.source_record.origin_url
      }
    })
  end

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

  @minutes_unmatched "minutes_items_unmatched"

  @doc "The classification of a case that leaves single minutes points unknown."
  def minutes_unmatched_classification, do: @minutes_unmatched

  @doc """
  Records what a successful minutes reading left unresolved.

  An earlier case about this source version is superseded by the reading and resolved,
  because a linked source record otherwise blocks its meeting page. Points the reading
  could not resolve keep one case listing their printed identifiers and reasons.
  """
  def reconcile_minutes(run, citation_url, receipt) do
    version = run.source_version
    source_record = version.source_record
    current = open_unmatched_case(run, version, source_record, citation_url, receipt)

    version.id
    |> BrusselsWtf.Review.list_open_normalization_cases_for_source_version!()
    |> Enum.reject(&(current && &1.id == current.id))
    |> Enum.each(&BrusselsWtf.Review.complete_retry!(&1.id))

    :ok
  end

  defp open_unmatched_case(_run, _version, _source_record, _citation_url, %{"unmatched" => []}),
    do: nil

  defp open_unmatched_case(run, version, source_record, citation_url, receipt) do
    unmatched = receipt["unmatched"]
    digest = unmatched |> :erlang.term_to_binary([:deterministic]) |> BrusselsWtf.Digest.sha256()

    BrusselsWtf.Review.open_review_case!(%{
      kind: :normalization,
      commune_id: source_record.commune_id,
      affected_record_id: version.id,
      affected_record_type: "source_version",
      source_record_id: source_record.id,
      source_version_id: version.id,
      processing_generation: "minutes-unmatched:#{version.id}:#{digest}",
      urgency: :normal,
      summary: "#{length(unmatched)} of #{receipt["points"]} minutes points stay unknown",
      normalized_content: receipt,
      diagnostics: %{
        "classification" => @minutes_unmatched,
        "detail" => "These points keep an unknown outcome; other points may publish"
      },
      related_evidence: %{
        "citation_url" => citation_url,
        "processing_run_id" => run.id
      }
    })
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
