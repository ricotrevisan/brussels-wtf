defmodule BrusselsWtf.Council.Provenance do
  @moduledoc "Derives public provenance labels from immutable processor-run methods."

  def labels(%{method: :ai_generation}, _canonical), do: [:ai_generated]
  def labels(%{method: :deterministic}, _canonical), do: []

  def labels(%{method: :human_edit, carried_provenance: provenance}, _canonical) do
    provenance
    |> Kernel.++([:human_reviewed])
    |> Enum.uniq()
  end

  def labels(%{method: :machine_translation}, canonical),
    do: Enum.uniq(labels(canonical, canonical) ++ [:machine_translated])

  def sufficient?(run, canonical, provenance) do
    Enum.all?(labels(run, canonical), &(&1 in provenance))
  end
end
