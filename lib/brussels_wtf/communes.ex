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
      index_url: "https://www.uccle.be/fr/ma-commune/le-conseil-communal",
      archive_index_url:
        "https://www.uccle.be/fr/ma-commune/le-conseil-communal/archives-du-Conseil-communal"
    },
    "forest" => %{
      name: "Forest",
      index_url: "https://forest.brussels/fr/publications/conseil-communal-1"
    },
    "city-of-brussels" => %{
      name: "City of Brussels",
      index_url: "https://www.brussels.be/agenda-reports-and-motions-city-council"
    }
  }

  def configuration!(slug), do: Map.fetch!(@municipalities, slug)

  @doc "Selects the explicit index root for a poll without changing stored locator history."
  def poll_index_url(%{slug: "uccle", index_url: index_url}, scope) do
    configuration = configuration!("uccle")

    if index_url in [configuration.index_url, configuration.archive_index_url] do
      if scope in [:previous_year, :backfill],
        do: configuration.archive_index_url,
        else: configuration.index_url
    else
      index_url
    end
  end

  def poll_index_url(%{index_url: index_url}, _scope), do: index_url

  @spec adapter(String.t()) :: {:ok, module()} | {:error, :adapter_not_implemented}
  def adapter("ixelles"), do: {:ok, BrusselsWtf.Communes.Ixelles}
  def adapter("uccle"), do: {:ok, BrusselsWtf.Communes.Uccle}
  def adapter("forest"), do: {:ok, BrusselsWtf.Communes.Forest}
  def adapter("city-of-brussels"), do: {:ok, BrusselsWtf.Communes.CityOfBrussels}
  def adapter(_slug), do: {:error, :adapter_not_implemented}

  @spec adapter!(String.t()) :: module()
  def adapter!(slug) do
    case adapter(slug) do
      {:ok, adapter} ->
        adapter

      {:error, :adapter_not_implemented} ->
        raise ArgumentError, "no commune adapter for #{inspect(slug)}"
    end
  end
end
