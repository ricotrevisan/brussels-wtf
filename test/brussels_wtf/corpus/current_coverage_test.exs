defmodule BrusselsWtf.Corpus.CurrentCoverageTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Corpus.Manifest
  alias BrusselsWtf.Processors.RecordedCorpusCoverage

  test "recorded generation provenance includes both fixed contracts without claiming human review" do
    metadata = RecordedCorpusCoverage.metadata()

    expected_hash =
      {Manifest.digest(), Manifest.digest("current-20260911")}
      |> :erlang.term_to_binary([:deterministic])
      |> BrusselsWtf.Digest.sha256()

    assert metadata.config_hash == "sha256:" <> expected_hash
    refute metadata.config_hash == "sha256:" <> Manifest.digest()
    assert metadata.processor_version == "2026-09-11"
    assert metadata.canonical_method == :ai_generation
    assert metadata.translation_method == :machine_translation
    assert metadata.billing_mode == :recorded
    assert metadata.network_access == :none
    assert metadata.usage == %{"network_calls" => 0}
    assert {:ok, 0} = RecordedCorpusCoverage.maximum_cost(:canonical_generation, %{})
    assert {:ok, 0} = RecordedCorpusCoverage.maximum_cost(:translation, %{})
  end
end
