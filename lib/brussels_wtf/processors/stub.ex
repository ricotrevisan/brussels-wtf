defmodule BrusselsWtf.Processors.Stub do
  @moduledoc false
  @behaviour BrusselsWtf.Processors

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)

  def put(sha256, outputs) when is_binary(sha256) and is_map(outputs) do
    Agent.update(__MODULE__, &Map.put(&1, sha256, outputs))
  end

  @impl true
  def extract(%{sha256: sha256}, _bytes), do: fetch(sha256, :extract)

  @impl true
  def normalize(%{"sha256" => sha256}), do: fetch(sha256, :normalize)
  def normalize(%{sha256: sha256}), do: fetch(sha256, :normalize)

  @impl true
  def generate_locales(%{"sha256" => sha256}), do: fetch(sha256, :locales)
  def generate_locales(%{sha256: sha256}), do: fetch(sha256, :locales)

  defp fetch(sha256, key) do
    case Agent.get(__MODULE__, &get_in(&1, [sha256, key])) do
      nil -> {:error, {:missing_processor_fixture, sha256, key}}
      {:error, reason} -> {:error, reason}
      value -> {:ok, value}
    end
  end
end
