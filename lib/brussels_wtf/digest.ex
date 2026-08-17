defmodule BrusselsWtf.Digest do
  @moduledoc false

  @spec sha256(binary()) :: String.t()
  def sha256(bytes) when is_binary(bytes) do
    :sha256
    |> :crypto.hash(bytes)
    |> Base.encode16(case: :lower)
  end
end
