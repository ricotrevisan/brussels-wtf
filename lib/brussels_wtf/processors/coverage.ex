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
  @doc "Returns a conservative upper bound for a request whose provider output is capped."
  @callback maximum_cost(:canonical_generation | :translation, map()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  def generate_fr(normalized), do: impl().generate_fr(normalized)
  def translate(canonical, locale), do: impl().translate(canonical, locale)
  def metadata, do: impl().metadata()

  def maximum_cost(operation, input) do
    processor = impl()

    if function_exported?(processor, :maximum_cost, 2),
      do: processor.maximum_cost(operation, input),
      else: {:error, :cost_estimate_unavailable}
  end

  defp impl, do: Application.fetch_env!(:brussels_wtf, :coverage_processor)
end
