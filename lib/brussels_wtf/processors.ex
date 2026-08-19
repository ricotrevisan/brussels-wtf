defmodule BrusselsWtf.Processors do
  @moduledoc """
  Extraction, normalization, and locale-generation adapters.

  Extraction/normalization and coverage processors use separate replaceable seams.
  Production coverage uses a versioned recorded contract; CI uses fixture-backed
  stubs and never depends on paid model calls.
  """

  @callback extract(meta :: map(), bytes :: binary()) :: {:ok, map()} | {:error, term()}
  @callback normalize(extracted :: map()) :: {:ok, map()} | {:error, term()}

  def extract(meta, bytes), do: impl().extract(meta, bytes)
  def normalize(extracted), do: impl().normalize(extracted)

  defp impl, do: Application.fetch_env!(:brussels_wtf, :processors)
end
