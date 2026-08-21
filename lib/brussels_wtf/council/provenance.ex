defmodule BrusselsWtf.Council.Provenance do
  @moduledoc "Derives public provenance labels from immutable processor-run methods."

  def labels(run, canonical) do
    (method_labels(run, canonical) ++ run.carried_provenance)
    |> Enum.uniq()
  end

  defp method_labels(%{method: :ai_generation}, _canonical), do: [:ai_generated]
  defp method_labels(%{method: :deterministic}, _canonical), do: []
  defp method_labels(%{method: :human_edit}, _canonical), do: [:human_reviewed]

  defp method_labels(%{method: :machine_translation}, canonical),
    do: labels(canonical, canonical) ++ [:machine_translated]

  def sufficient?(run, canonical, provenance) do
    Enum.all?(labels(run, canonical), &(&1 in provenance))
  end
end
