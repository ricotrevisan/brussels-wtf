defmodule BrusselsWtf.Communes do
  @moduledoc """
  Registry of explicit commune discovery adapters.
  """

  @spec adapter!(String.t()) :: module()
  def adapter!("ixelles"), do: BrusselsWtf.Communes.Ixelles

  def adapter!(slug) do
    raise ArgumentError, "no commune adapter for #{inspect(slug)}"
  end
end
