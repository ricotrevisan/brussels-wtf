defmodule BrusselsWtf.CBE.Index.Manifest do
  @moduledoc false
  alias BrusselsWtf.CBE.Source

  def validate!(directory, manifest) do
    unless is_binary(directory) and is_map(manifest) and valid_sha?(manifest["sha256"]) and
             is_map(manifest["metadata"]) and is_map(manifest["files"]) and
             Enum.sort(Map.keys(manifest["files"])) == Enum.sort(Source.files()) and
             byte_size(Jason.encode!(manifest)) <= 1_048_576 do
      throw({:index_error, :invalid_manifest})
    end

    Enum.each(Source.files(), fn file ->
      expected = manifest["files"][file]

      unless is_map(expected) and is_integer(expected["bytes"]) and expected["bytes"] > 0 and
               valid_sha?(expected["sha256"]) do
        throw({:index_error, :invalid_manifest})
      end

      # These reference tables are loaded with each bundle, never the full index.
      if file in ["meta.csv", "code.csv"] and expected["bytes"] > 16_777_216 do
        throw({:index_error, :reference_file_too_large})
      end

      {hash, bytes} =
        directory
        |> Path.join(file)
        |> File.stream!(65_536)
        |> Enum.reduce({:crypto.hash_init(:sha256), 0}, fn chunk, {hash, bytes} ->
          {:crypto.hash_update(hash, chunk), bytes + byte_size(chunk)}
        end)

      actual = Base.encode16(:crypto.hash_final(hash), case: :lower)

      unless actual == expected["sha256"] and bytes == expected["bytes"],
        do: throw({:index_error, :manifest_mismatch})
    end)
  end

  def valid_sha?(sha), do: is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{64}\z/, sha)
end
