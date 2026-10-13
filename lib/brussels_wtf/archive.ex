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
  @callback fetch_file(String.t(), String.t(), non_neg_integer(), Path.t(), keyword()) ::
              {:ok, %{object_key: String.t(), sha256: String.t(), byte_size: non_neg_integer()}}
              | {:error, term()}

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

  @doc """
  Fetches a hash-pinned snapshot into a new file in a caller-owned 0700 directory.
  The directory must not be a symlink and must reside on a filesystem supporting
  exclusive creation. The new file is set to 0600 before any archive read or write.
  Existing files and symlinks are never replaced. Failures remove only the new file.

  Returns only immutable archive metadata; the caller owns successful-file cleanup.
  `max_bytes` is a required positive cap; expected size must fit within it.
  `timeout_ms` (default 60_000) bounds the entire read, while `receive_timeout_ms`
  (default 15_000) bounds socket receives. Both must be positive and at most 3_600_000.
  A read never retries internally; the caller owns retry policy.
  """
  @spec fetch_file(String.t(), String.t(), non_neg_integer(), Path.t(), keyword()) ::
          {:ok, %{object_key: String.t(), sha256: String.t(), byte_size: non_neg_integer()}}
          | {:error, term()}
  def fetch_file(object_key, sha256, size, destination, opts),
    do: impl().fetch_file(object_key, sha256, size, destination, opts)

  @doc false
  def with_fetch_file(object_key, sha256, size, destination, opts, read) do
    with :ok <- validate_fetch(object_key, sha256, size, opts),
         :ok <- validate_destination(destination) do
      create_fetch_file(object_key, sha256, size, destination, opts, read)
    end
  end

  defp validate_fetch(key, hash, size, opts) do
    if is_list(opts) and Keyword.keyword?(opts) do
      cap = Keyword.get(opts, :max_bytes)
      timeout = Keyword.get(opts, :timeout_ms, 60_000)
      receive_timeout = Keyword.get(opts, :receive_timeout_ms, 15_000)

      cond do
        not (is_integer(cap) and cap > 0) ->
          {:error, :invalid_max_bytes}

        not (is_integer(size) and size >= 0) ->
          {:error, :invalid_size}

        size > cap ->
          {:error, :max_bytes_exceeded}

        not (is_binary(hash) and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)) ->
          {:error, :invalid_sha256}

        key not in [object_key(hash, :raw), object_key(hash, :derived)] ->
          {:error, :invalid_object_key}

        not (is_integer(timeout) and timeout > 0 and timeout <= 3_600_000 and
               is_integer(receive_timeout) and receive_timeout > 0 and
                 receive_timeout <= 3_600_000) ->
          {:error, :invalid_timeout}

        true ->
          :ok
      end
    else
      {:error, :invalid_options}
    end
  end

  defp validate_destination(destination) when is_binary(destination) do
    case File.lstat(Path.dirname(destination)) do
      {:ok, %{type: :directory, mode: mode}} ->
        if Bitwise.band(mode, 0o777) == 0o700,
          do: :ok,
          else: {:error, :invalid_destination_directory}

      _ ->
        {:error, :invalid_destination_directory}
    end
  end

  defp validate_destination(_), do: {:error, :invalid_destination_directory}

  defp create_fetch_file(object_key, sha256, size, destination, opts, read) do
    case File.open(destination, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        result =
          try do
            with :ok <- File.chmod(destination, 0o600),
                 :ok <- bounded_read(io, opts, read) do
              {:ok, %{object_key: object_key, sha256: sha256, byte_size: size}}
            end
          after
            File.close(io)
          end

        if not match?({:ok, _}, result), do: File.rm(destination)
        result

      {:error, reason} ->
        {:error, {:destination, reason}}
    end
  end

  defp bounded_read(io, opts, read) do
    # Catch failures inside the task so Task never logs private exception details.
    task =
      Task.async(fn ->
        try do
          read.(io)
        rescue
          _ -> {:error, :archive_unavailable}
        catch
          _, _ -> {:error, :archive_unavailable}
        end
      end)

    case Task.yield(task, Keyword.get(opts, :timeout_ms, 60_000)) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :archive_timeout}
    end
  end

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
