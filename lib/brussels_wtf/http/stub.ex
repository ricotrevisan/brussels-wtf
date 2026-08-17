defmodule BrusselsWtf.HTTP.Stub do
  @moduledoc false
  @behaviour BrusselsWtf.HTTP

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{responses: %{}, requests: []} end, name: __MODULE__)
  end

  def reset, do: Agent.update(__MODULE__, fn _ -> %{responses: %{}, requests: []} end)

  def put(url, response) when is_binary(url) and is_map(response) do
    Agent.update(__MODULE__, &put_in(&1, [:responses, url], {:ok, normalize(url, response)}))
  end

  def put_error(url, reason) when is_binary(url) do
    failure = normalize_failure(url, reason)
    Agent.update(__MODULE__, &put_in(&1, [:responses, url], {:error, failure}))
  end

  def requests(url) do
    Agent.get(__MODULE__, fn state -> Enum.filter(state.requests, &(&1.url == url)) end)
  end

  @impl true
  def get(url, opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      request = %{url: url, headers: normalize_headers(Keyword.get(opts, :headers, %{}))}

      result =
        Map.get(state.responses, url, {:error, normalize_failure(url, {:unexpected_url, url})})

      {result, %{state | requests: state.requests ++ [request]}}
    end)
  end

  defp normalize(url, response) do
    %{
      status: Map.get(response, :status, 200),
      headers: normalize_headers(Map.get(response, :headers) || %{}),
      body: Map.get(response, :body, ""),
      final_url: Map.get(response, :final_url) || url,
      redirect_chain: Map.get(response, :redirect_chain) || []
    }
  end

  defp normalize_failure(url, %{reason: _} = failure) do
    %{
      reason: failure.reason,
      final_url: Map.get(failure, :final_url, url),
      response_headers: normalize_headers(Map.get(failure, :response_headers, %{})),
      redirect_chain: Map.get(failure, :redirect_chain, [])
    }
  end

  defp normalize_failure(url, reason) do
    %{reason: reason, final_url: url, response_headers: %{}, redirect_chain: []}
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {key, values} -> {String.downcase(to_string(key)), List.wrap(values)} end)
  end
end
