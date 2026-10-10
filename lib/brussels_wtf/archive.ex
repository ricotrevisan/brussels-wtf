defmodule BrusselsWtf.Archive do
  @moduledoc """
  Private content-addressed store for immutable source bytes.

  `store/1` and `store_file/1` derive the identity from the raw bytes and
  verify a read-after-write before returning an object key. File callers keep
  their source unchanged until acceptance and own its cleanup.
  """

  @callback put(namespace :: :raw | :derived, sha256 :: String.t(), bytes :: binary()) ::
              {:ok, object_key :: String.t()} | {:error, term()}
  @callback put_file(:raw | :derived, String.t(), Path.t(), non_neg_integer()) ::
              {:ok, String.t()} | {:error, term()}
  @callback verify_file(String.t(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  @callback get(object_key :: String.t()) :: {:ok, binary()} | {:error, :not_found | term()}
  @callback ready?() :: :ok | {:error, term()}

  @spec store(binary()) ::
          {:ok, %{sha256: String.t(), object_key: String.t()}} | {:error, term()}
  def store(bytes, namespace \\ :raw) when is_binary(bytes) and namespace in [:raw, :derived] do
    sha256 = BrusselsWtf.Digest.sha256(bytes)

    with {:ok, object_key} <- put(namespace, sha256, bytes),
         {:ok, archived_bytes} <- get(object_key),
         actual <- BrusselsWtf.Digest.sha256(archived_bytes),
         :ok <- verify_hash(sha256, actual) do
      {:ok, %{sha256: sha256, object_key: object_key}}
    end
  end

  @doc "Stores a caller-owned file and verifies the archived bytes without loading the file."
  @spec store_file(Path.t(), :raw | :derived) ::
          {:ok, %{sha256: String.t(), object_key: String.t(), byte_size: non_neg_integer()}}
          | {:error, term()}
  def store_file(path, namespace \\ :raw) when namespace in [:raw, :derived] do
    with {:ok, %{sha256: sha256, byte_size: size}} <- BrusselsWtf.Digest.sha256_file(path),
         {:ok, object_key} <- impl().put_file(namespace, sha256, path, size),
         :ok <- impl().verify_file(object_key, sha256, size) do
      {:ok, %{sha256: sha256, object_key: object_key, byte_size: size}}
    end
  end

  @spec put(String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def put(sha256, bytes), do: put(:raw, sha256, bytes)
  def put(namespace, sha256, bytes), do: impl().put(namespace, sha256, bytes)

  @spec get(String.t()) :: {:ok, binary()} | {:error, :not_found | term()}
  def get(object_key), do: impl().get(object_key)

  @spec ready?() :: :ok | {:error, term()}
  def ready?, do: impl().ready?()

  def object_key(sha256, namespace \\ :raw) when namespace in [:raw, :derived] do
    prefix = String.slice(sha256, 0, 2)
    "#{namespace}/sha256/#{prefix}/#{sha256}"
  end

  defp verify_hash(value, value), do: :ok
  defp verify_hash(expected, actual), do: {:error, {:hash_mismatch, expected, actual}}

  defp impl, do: Application.fetch_env!(:brussels_wtf, :archive)
end
