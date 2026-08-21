defmodule BrusselsWtf.Processors.RecordedCorpusCoverage do
  @moduledoc "Zero-network recorded coverage for the bounded issue-33 real corpus."
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
    %{
      processor_name: "recorded-real-corpus-coverage",
      processor_version: "2026-08-21",
      config_hash: "sha256:" <> BrusselsWtf.Corpus.Manifest.digest(),
      provider_category: "recorded_agent_assisted_editorial",
      billing_mode: :recorded,
      network_access: :none,
      model: "openai-codex/gpt-5.6-sol",
      canonical_method: :ai_generation,
      translation_method: :machine_translation,
      usage: %{"network_calls" => 0}
    }
  end
end
