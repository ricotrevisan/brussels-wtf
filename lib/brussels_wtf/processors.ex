defmodule BrusselsWtf.Processors do
  @moduledoc """
  Extraction, normalization, and locale-generation adapters.

  Production processors are selected later. The principal seam uses a
  fixture-backed stub so CI does not depend on binaries or model calls.
  """

  @callback extract(meta :: map(), bytes :: binary()) :: {:ok, map()} | {:error, term()}
  @callback normalize(extracted :: map()) :: {:ok, map()} | {:error, term()}
  @callback generate_locales(normalized :: map()) :: {:ok, map()} | {:error, term()}

  def extract(meta, bytes), do: impl().extract(meta, bytes)
  def normalize(extracted), do: impl().normalize(extracted)
  def generate_locales(normalized), do: impl().generate_locales(normalized)

  defp impl, do: Application.fetch_env!(:brussels_wtf, :processors)
end
