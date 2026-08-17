defmodule BrusselsWtf.Archive do
  @moduledoc """
  Private content-addressed store for immutable source bytes.
  """

  @callback put(sha256 :: String.t(), bytes :: binary()) ::
              {:ok, object_key :: String.t()} | {:error, term()}
  @callback get(object_key :: String.t()) :: {:ok, binary()} | {:error, :not_found | term()}

  @spec put(String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def put(sha256, bytes), do: impl().put(sha256, bytes)

  @spec get(String.t()) :: {:ok, binary()} | {:error, :not_found | term()}
  def get(object_key), do: impl().get(object_key)

  def object_key(sha256) do
    prefix = String.slice(sha256, 0, 2)
    "raw/sha256/#{prefix}/#{sha256}"
  end

  defp impl, do: Application.fetch_env!(:brussels_wtf, :archive)
end
