defmodule BrusselsWtf.Council.PublicationMetadata do
  @moduledoc "Builds the evidence, processor, locale, provenance, and gate audit set for publication."

  alias BrusselsWtf.Council.Provenance

  @locales ["fr", "nl", "en"]

  def build(input, runs, gate_result) do
    canonical = Map.fetch!(runs, "fr")

    %{
      "gate_result" => serialize_gate(gate_result),
      "locales" => @locales,
      "evidence" => evidence_set(input),
      "provenance" =>
        Map.new(@locales, fn locale ->
          labels = runs |> Map.fetch!(locale) |> Provenance.labels(canonical)
          {locale, Enum.map(labels, &Atom.to_string/1)}
        end),
      "processors" => Map.new(@locales, &processor_entry(&1, Map.fetch!(runs, &1)))
    }
  end

  defp serialize_gate(gate_result) do
    %{
      "ready" => gate_result.ready?,
      "input_hash" => gate_result.input_hash,
      "failures" =>
        Enum.map(gate_result.failures, fn failure ->
          failure
          |> Map.take([:code, :item_key, :claim_key, :locale, :review_case_id])
          |> Map.new(fn {key, value} -> {Atom.to_string(key), serialize_value(value)} end)
        end)
    }
  end

  defp processor_entry(locale, run) do
    {locale,
     %{
       "coverage_run_id" => run.id,
       "name" => run.processor_name,
       "version" => run.processor_version,
       "config_hash" => run.config_hash,
       "method" => Atom.to_string(run.method)
     }}
  end

  defp evidence_set(input) do
    input
    |> Map.get("items", [])
    |> Enum.flat_map(fn item ->
      Enum.flat_map(item["claims"], fn claim ->
        Enum.map(claim["evidence"], fn evidence ->
          %{
            "item_key" => item["key"],
            "claim_key" => claim["key"],
            "citation_url" => evidence["citation_url"],
            "source_sha256" => evidence["source_sha256"],
            "location" => evidence["location"],
            "retrieved_at" => evidence["retrieved_at"]
          }
        end)
      end)
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1["item_key"], &1["claim_key"], &1["source_sha256"], &1["location"]})
  end

  defp serialize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp serialize_value(value), do: value
end
