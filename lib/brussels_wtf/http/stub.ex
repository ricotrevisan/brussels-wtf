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

  @impl true
  def download(url, destination_path, opts) do
    result = get(url, opts)

    with :ok <- File.write(destination_path, "") do
      case result do
        {:ok, %{status: status} = response} when status in 201..299 ->
          {:error,
           download_failure(response, {:invalid_content, {:unexpected_success_status, status}})}

        {:ok, response} ->
          body = if response.status == 200, do: response.body, else: ""

          limit =
            Keyword.get(
              opts,
              :max_body_bytes,
              Application.get_env(:brussels_wtf, :http_max_body_bytes, 25 * 1_024 * 1_024)
            )

          if byte_size(body) > limit do
            {:error, download_failure(response, {:body_too_large, limit})}
          else
            case File.write(destination_path, body) do
              :ok -> {:ok, response |> Map.delete(:body) |> Map.put(:byte_size, byte_size(body))}
              {:error, reason} -> {:error, download_failure(response, {:file_write, reason})}
            end
          end

        {:error, _failure} = error ->
          error
      end
    else
      {:error, reason} -> {:error, normalize_failure(url, {:file_write, reason})}
    end
  end

  defp download_failure(response, reason) do
    %{
      reason: reason,
      final_url: response.final_url,
      response_headers: response.headers,
      redirect_chain: response.redirect_chain
    }
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
