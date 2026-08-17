defmodule BrusselsWtf.Communes do
  @moduledoc """
  Registry of explicit commune discovery adapters.
  """

  @municipalities %{
    "ixelles" => %{
      name: "Ixelles",
      index_url: "https://www.ixelles.be/site/11-Ordres-du-jour-et-proces-verbaux?langue=fr"
    },
    "uccle" => %{
      name: "Uccle",
      index_url:
        "https://www.uccle.be/fr/ma-commune/le-conseil-communal/archives-du-Conseil-communal"
    },
    "forest" => %{name: "Forest", index_url: "https://forest.brussels/fr/publications"},
    "city-of-brussels" => %{
      name: "City of Brussels",
      index_url: "https://www.brussels.be/agenda-reports-and-motions-city-council"
    }
  }

  def configuration!(slug), do: Map.fetch!(@municipalities, slug)

  @spec adapter!(String.t()) :: module()
  def adapter!("ixelles"), do: BrusselsWtf.Communes.Ixelles

  def adapter!(slug) do
    raise ArgumentError, "no commune adapter for #{inspect(slug)}"
  end
end
