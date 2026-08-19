defmodule BrusselsWtf.Processors.Coverage do
  @moduledoc "Replaceable canonical-generation and translation processor seam."

  @type result ::
          {:ok, map()}
          | {:ok, map(), map()}
          | {:error, term()}
          | {:error, term(), map()}

  @callback generate_fr(normalized :: map()) :: result()
  @callback translate(canonical :: map(), locale :: String.t()) :: result()
  @callback metadata() :: map()

  def generate_fr(normalized), do: impl().generate_fr(normalized)
  def translate(canonical, locale), do: impl().translate(canonical, locale)
  def metadata, do: impl().metadata()

  defp impl, do: Application.fetch_env!(:brussels_wtf, :coverage_processor)
end
