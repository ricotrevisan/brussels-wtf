defmodule BrusselsWtf.CBE.Stub do
  @moduledoc false
  @behaviour BrusselsWtf.CBE

  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
  def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)

  def put(enterprise_number, result) do
    Agent.update(__MODULE__, &Map.put(&1, enterprise_number, result))
  end

  @impl true
  def fetch_enterprise(enterprise_number) do
    Agent.get(__MODULE__, &Map.get(&1, enterprise_number, {:error, :not_found}))
  end
end
