defmodule BrusselsWtf.HTTP.Stub do
  @moduledoc false
  @behaviour BrusselsWtf.HTTP

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)

  def put(url, response) when is_binary(url) and is_map(response) do
    Agent.update(__MODULE__, &Map.put(&1, url, normalize(url, response)))
  end

  @impl true
  def get(url) do
    case Agent.get(__MODULE__, &Map.fetch(&1, url)) do
      {:ok, response} -> {:ok, response}
      :error -> {:error, {:unexpected_url, url}}
    end
  end

  defp normalize(url, response) do
    %{
      status: Map.get(response, :status, 200),
      headers: Map.get(response, :headers, []),
      body: Map.fetch!(response, :body),
      final_url: Map.get(response, :final_url, url)
    }
  end
end
