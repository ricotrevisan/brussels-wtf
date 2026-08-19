defmodule BrusselsWtfWeb.PublicEvidence do
  @moduledoc false

  def proposals(%{proposals: %Ash.NotLoaded{}}), do: []

  def proposals(%{proposals: proposals} = item) do
    {synthetic, authoritative} = Enum.split_with(proposals, & &1.synthetic)

    current_authoritative =
      if Map.has_key?(item, :published_proposal) do
        case Map.get(item, :published_proposal) do
          %Ash.NotLoaded{} -> newest_proposal(authoritative)
          nil -> []
          proposal -> [proposal]
        end
      else
        newest_proposal(authoritative)
      end

    Enum.sort_by(synthetic ++ current_authoritative, &proposal_sort_key/1)
  end

  defp newest_proposal(authoritative) do
    case Enum.reject(authoritative, &match?(%Ash.NotLoaded{}, &1.source_version)) do
      [] -> []
      versions -> [newest(versions, & &1.source_version)]
    end
  end

  def source_proposals(item) do
    item
    |> proposals()
    |> Enum.reject(& &1.synthetic)
  end

  def for_item(item) do
    proposal_evidence =
      item
      |> proposals()
      |> Enum.flat_map(fn proposal ->
        proposal.evidence
        |> loaded_list()
        |> current_evidence()
      end)

    decision_evidence =
      case loaded_value(Map.get(item, :published_decision)) do
        nil -> []
        decision -> decision.evidence |> loaded_list() |> current_evidence()
      end

    (proposal_evidence ++ decision_evidence)
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(&presentation/1)
  end

  defp current_evidence(evidence) do
    {synthetic, authoritative} = Enum.split_with(evidence, & &1.synthetic)

    current_authoritative =
      authoritative
      |> Enum.reject(&match?(%Ash.NotLoaded{}, &1.source_version))
      |> Enum.group_by(&{&1.claim, &1.source_version.source_record_id})
      |> Enum.map(fn {_lineage, versions} -> newest(versions, & &1.source_version) end)

    Enum.sort_by(synthetic ++ current_authoritative, & &1.id)
  end

  defp newest(records, source_version) do
    Enum.max_by(records, fn record ->
      version = source_version.(record)

      {
        DateTime.to_unix(version.first_retrieved_at, :microsecond),
        DateTime.to_unix(version.inserted_at, :microsecond),
        version.id
      }
    end)
  end

  defp proposal_sort_key(%{synthetic: true} = proposal), do: {1, proposal.id}

  defp proposal_sort_key(proposal),
    do: {0, proposal.source_version.source_record_id, proposal.source_version.id}

  defp presentation(evidence) do
    source_version = loaded_value(evidence.source_version)

    %{
      citation_url: evidence.citation_url,
      source_title: evidence.source_title || "Authoritative municipal source",
      location: evidence.location,
      retrieved_at: evidence.retrieved_at,
      synthetic: evidence.synthetic,
      checksum: source_version && source_version.sha256
    }
  end

  defp loaded_list(%Ash.NotLoaded{}), do: []
  defp loaded_list(values), do: values

  defp loaded_value(%Ash.NotLoaded{}), do: nil
  defp loaded_value(value), do: value
end
