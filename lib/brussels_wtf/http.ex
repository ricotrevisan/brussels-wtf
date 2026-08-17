defmodule BrusselsWtf.HTTP do
  @moduledoc "Retrieval adapter for municipal indexes and source locators."

  @type request_options :: [headers: map()]

  @type response :: %{
          status: pos_integer(),
          headers: map(),
          body: binary(),
          final_url: String.t(),
          redirect_chain: [map()]
        }

  @type failure :: %{
          reason: term(),
          final_url: String.t(),
          response_headers: map(),
          redirect_chain: [map()]
        }

  @callback get(url :: String.t(), request_options()) ::
              {:ok, response()} | {:error, failure()}

  @spec get(String.t(), request_options()) :: {:ok, response()} | {:error, failure()}
  def get(url, opts \\ []) when is_binary(url), do: impl().get(url, opts)

  defp impl, do: Application.fetch_env!(:brussels_wtf, :http)
end
