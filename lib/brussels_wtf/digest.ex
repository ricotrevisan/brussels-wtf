defmodule BrusselsWtf.Digest do
  @moduledoc false

  @spec sha256(binary()) :: String.t()
  def sha256(bytes) when is_binary(bytes) do
    :sha256
    |> :crypto.hash(bytes)
    |> Base.encode16(case: :lower)
  end

  @doc "Hashes a file in fixed-size chunks without retaining its bytes."
  @spec sha256_file(Path.t()) ::
          {:ok, %{sha256: String.t(), byte_size: non_neg_integer()}} | {:error, term()}
  def sha256_file(path) do
    {context, size} =
      path
      |> File.stream!(64 * 1_024)
      |> Enum.reduce({:crypto.hash_init(:sha256), 0}, fn chunk, {context, size} ->
        {:crypto.hash_update(context, chunk), size + byte_size(chunk)}
      end)

    {:ok, %{sha256: Base.encode16(:crypto.hash_final(context), case: :lower), byte_size: size}}
  rescue
    error in File.Error -> {:error, {:file_read, error.reason}}
  end
end
