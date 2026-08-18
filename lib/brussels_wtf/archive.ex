defmodule BrusselsWtf.Archive do
  @moduledoc """
  Private content-addressed store for immutable source bytes.

  `store/1` is the acceptance boundary: it derives the identity from the raw
  bytes and verifies a read-after-write before returning an object key.
  """

  @callback put(sha256 :: String.t(), bytes :: binary()) ::
              {:ok, object_key :: String.t()} | {:error, term()}
  @callback get(object_key :: String.t()) :: {:ok, binary()} | {:error, :not_found | term()}
  @callback ready?() :: :ok | {:error, term()}

  @spec store(binary()) ::
          {:ok, %{sha256: String.t(), object_key: String.t()}} | {:error, term()}
  def store(bytes) when is_binary(bytes) do
    sha256 = BrusselsWtf.Digest.sha256(bytes)

    with {:ok, object_key} <- put(sha256, bytes),
         {:ok, archived_bytes} <- get(object_key),
         actual <- BrusselsWtf.Digest.sha256(archived_bytes),
         :ok <- verify_hash(sha256, actual) do
      {:ok, %{sha256: sha256, object_key: object_key}}
    end
  end

  @spec put(String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def put(sha256, bytes), do: impl().put(sha256, bytes)

  @spec get(String.t()) :: {:ok, binary()} | {:error, :not_found | term()}
  def get(object_key), do: impl().get(object_key)

  @spec ready?() :: :ok | {:error, term()}
  def ready?, do: impl().ready?()

  def object_key(sha256) do
    prefix = String.slice(sha256, 0, 2)
    "raw/sha256/#{prefix}/#{sha256}"
  end

  defp verify_hash(value, value), do: :ok
  defp verify_hash(expected, actual), do: {:error, {:hash_mismatch, expected, actual}}

  defp impl, do: Application.fetch_env!(:brussels_wtf, :archive)
end
