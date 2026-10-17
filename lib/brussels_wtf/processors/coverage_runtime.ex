defmodule BrusselsWtf.Processors.CoverageRuntime do
  @moduledoc "Explicit coverage provider selection with credential-free recorded defaults."

  alias BrusselsWtf.Council.GenerationControl

  def load(get_env \\ &System.get_env/1) do
    generation = GenerationControl.runtime_config(get_env)

    case get_env.("COVERAGE_PROCESSOR") do
      value when value in [nil, "", "recorded"] ->
        if generation.mode == :paid do
          raise ArgumentError, "paid coverage requires opencode as COVERAGE_PROCESSOR"
        end

        %{
          processor: BrusselsWtf.Processors.RecordedCorpusCoverage,
          generation: generation,
          provider_config: []
        }

      "opencode" ->
        unless generation.mode in [:paid, :disabled] do
          raise ArgumentError, "OpenCode requires paid or disabled coverage generation mode"
        end

        key = get_env.("OPENCODE_API_KEY")

        if generation.mode == :paid and
             (not is_binary(key) or String.trim(key) != key or byte_size(key) not in 1..512 or
                String.contains?(key, ["\n", "\r", "op://"])) do
          raise ArgumentError, "OPENCODE_API_KEY is required for OpenCode coverage"
        end

        %{
          processor: BrusselsWtf.Processors.OpenCodeCoverage,
          generation: generation,
          provider_config: if(generation.mode == :paid, do: [api_key: key], else: [])
        }

      _ ->
        raise ArgumentError, "COVERAGE_PROCESSOR must be recorded or opencode"
    end
  end
end
