defmodule BrusselsWtf.HTTP do
  @moduledoc "Retrieval adapter for municipal indexes and source locators."

  @type request_options :: [
          {:headers, map()} | {:max_body_bytes, pos_integer()} | {:receive_timeout, pos_integer()}
        ]

  @type response :: %{
          status: pos_integer(),
          headers: map(),
          body: binary(),
          final_url: String.t(),
          redirect_chain: [map()]
        }

  @type download_response :: %{
          status: pos_integer(),
          headers: map(),
          final_url: String.t(),
          redirect_chain: [map()],
          byte_size: non_neg_integer()
        }

  @type failure :: %{
          reason: term(),
          final_url: String.t(),
          response_headers: map(),
          redirect_chain: [map()]
        }

  @callback get(url :: String.t(), request_options()) ::
              {:ok, response()} | {:error, failure()}

  @callback download(url :: String.t(), destination_path :: Path.t(), request_options()) ::
              {:ok, download_response()} | {:error, failure()}

  @optional_callbacks download: 3

  @spec get(String.t(), request_options()) :: {:ok, response()} | {:error, failure()}
  def get(url, opts \\ []) when is_binary(url), do: impl().get(url, opts)

  @doc "Streams a response to a caller-owned file. Only status 200 writes source bytes."
  @spec download(String.t(), Path.t(), request_options()) ::
          {:ok, download_response()} | {:error, failure()}
  def download(url, destination_path, opts \\ []) when is_binary(url),
    do: impl().download(url, destination_path, opts)

  defp impl, do: Application.fetch_env!(:brussels_wtf, :http)
end
