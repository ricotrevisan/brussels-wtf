defmodule BrusselsWtf.Archive.Memory do
  @moduledoc false
  @behaviour BrusselsWtf.Archive

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)

  @impl true
  def put(sha256, bytes) do
    key = BrusselsWtf.Archive.object_key(sha256)

    Agent.get_and_update(__MODULE__, fn objects ->
      case Map.fetch(objects, key) do
        :error -> {{:ok, key}, Map.put(objects, key, bytes)}
        {:ok, ^bytes} -> {{:ok, key}, objects}
        {:ok, _different_bytes} -> {{:error, :content_address_collision}, objects}
      end
    end)
  end

  @impl true
  def get(object_key) do
    case Agent.get(__MODULE__, &Map.fetch(&1, object_key)) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :not_found}
    end
  end
end
