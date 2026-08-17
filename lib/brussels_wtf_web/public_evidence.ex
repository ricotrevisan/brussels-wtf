defmodule BrusselsWtfWeb.PublicEvidence do
  @moduledoc false

  def proposals(%{proposals: %Ash.NotLoaded{}}), do: []

  def proposals(%{proposals: proposals, current_source_version_id: current_source_version_id}) do
    Enum.filter(proposals, fn proposal ->
      proposal.synthetic or proposal.source_version_id == current_source_version_id
    end)
  end

  def source_proposals(item) do
    item
    |> proposals()
    |> Enum.reject(& &1.synthetic)
  end

  def for_item(item) do
    item
    |> proposals()
    |> Enum.flat_map(fn proposal ->
      proposal.evidence
      |> loaded_list()
      |> Enum.map(&presentation/1)
    end)
  end

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
