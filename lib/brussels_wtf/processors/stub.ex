defmodule BrusselsWtf.Processors.Stub do
  @moduledoc false
  @behaviour BrusselsWtf.Processors
  @behaviour BrusselsWtf.Processors.Coverage

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)

  def put(sha256, outputs) when is_binary(sha256) and is_map(outputs) do
    Agent.update(__MODULE__, &Map.put(&1, sha256, outputs))
  end

  def put_locales(meeting_identifier, output)
      when is_binary(meeting_identifier) and is_map(output) do
    Agent.update(__MODULE__, &Map.put(&1, {:locales, meeting_identifier}, output))
  end

  @impl true
  def extract(%{sha256: sha256}, _bytes), do: fetch(sha256, :extract)

  @impl true
  def normalize(%{"sha256" => sha256}), do: fetch(sha256, :normalize)
  def normalize(%{sha256: sha256}), do: fetch(sha256, :normalize)

  @impl true
  def metadata do
    %{
      processor_name: "recorded-coverage-generator",
      processor_version: "fixture-contract-1",
      config_hash: "sha256:fixture-coverage-contract-1",
      provider_category: "recorded_fixture",
      model: "recorded-ixelles-proposal",
      canonical_method: :ai_generation,
      translation_method: :machine_translation,
      usage: %{"fixture" => true}
    }
  end

  @impl true
  def generate_fr(%{"meeting_identifier" => meeting_identifier}) do
    with {:ok, output} <- generation_fixture(meeting_identifier) do
      {:ok, locale_bundle(output, meeting_identifier, "fr")}
    end
  end

  @impl true
  def translate(%{"meeting_identifier" => meeting_identifier}, locale)
      when locale in ["nl", "en"] do
    with {:ok, output} <- generation_fixture(meeting_identifier) do
      {:ok, locale_bundle(output, meeting_identifier, locale)}
    end
  end

  defp generation_fixture(meeting_identifier) do
    case Agent.get(__MODULE__, &Map.get(&1, {:locales, meeting_identifier})) do
      nil -> {:error, {:missing_generation_fixture, meeting_identifier}}
      output -> {:ok, output}
    end
  end

  defp locale_bundle(output, meeting_identifier, locale) do
    page_claim_refs =
      output["items"]
      |> Map.values()
      |> Enum.flat_map(& &1["claim_refs"])
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "meeting_identifier" => meeting_identifier,
      "page" =>
        case get_in(output, ["page", locale]) do
          nil -> nil
          page -> Map.put(page, "claim_refs", page_claim_refs)
        end,
      "items" =>
        Map.new(output["items"], fn {item_key, item} ->
          {item_key,
           %{
             "claim_refs" => item["claim_refs"],
             "variant" => get_in(item, ["variants", locale])
           }}
        end)
    }
  end

  defp fetch(sha256, key) do
    case Agent.get(__MODULE__, &get_in(&1, [sha256, key])) do
      nil -> {:error, {:missing_processor_fixture, sha256, key}}
      {:error, reason} -> {:error, reason}
      value -> {:ok, value}
    end
  end
end
