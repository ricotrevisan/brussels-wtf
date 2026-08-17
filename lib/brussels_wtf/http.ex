defmodule BrusselsWtf.HTTP do
  @moduledoc """
  Retrieval adapter for municipal indexes and source locators.
  """

  @type response :: %{
          status: pos_integer(),
          headers: term(),
          body: binary(),
          final_url: String.t()
        }

  @callback get(url :: String.t()) :: {:ok, response()} | {:error, term()}

  @spec get(String.t()) :: {:ok, response()} | {:error, term()}
  def get(url) when is_binary(url), do: impl().get(url)

  defp impl, do: Application.fetch_env!(:brussels_wtf, :http)
end
