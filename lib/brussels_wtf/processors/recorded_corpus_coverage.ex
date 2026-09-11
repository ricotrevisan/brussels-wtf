defmodule BrusselsWtf.Processors.RecordedCorpusCoverage do
  @moduledoc "Zero-network recorded coverage for the fixed historic and current selections."
  @behaviour BrusselsWtf.Processors.Coverage

  @impl true
  def generate_fr(input), do: BrusselsWtf.Corpus.Manifest.recorded_bundle(input, "fr")

  @impl true
  def translate(canonical, locale),
    do: BrusselsWtf.Corpus.Manifest.recorded_translation(canonical, locale)

  @impl true
  def maximum_cost(_operation, _input), do: {:ok, 0}

  @impl true
  def metadata do
    config_hash =
      {BrusselsWtf.Corpus.Manifest.digest(),
       BrusselsWtf.Corpus.Manifest.digest("current-20260911")}
      |> :erlang.term_to_binary([:deterministic])
      |> BrusselsWtf.Digest.sha256()

    %{
      processor_name: "recorded-real-corpus-coverage",
      processor_version: "2026-09-11",
      config_hash: "sha256:" <> config_hash,
      provider_category: "recorded_agent_assisted_editorial",
      billing_mode: :recorded,
      network_access: :none,
      model: "openai-codex/agent-assisted",
      canonical_method: :ai_generation,
      translation_method: :machine_translation,
      usage: %{"network_calls" => 0}
    }
  end
end
