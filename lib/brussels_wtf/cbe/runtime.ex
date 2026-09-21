defmodule BrusselsWtf.CBE.Runtime do
  @moduledoc "Selects a CBE adapter without accessing source files or the database."

  alias BrusselsWtf.CBE.{Indexed, OpenData, Unconfigured}

  def load(env \\ System.get_env()) when is_map(env) do
    directory = present(env["CBE_OPEN_DATA_DIRECTORY"])
    sha256 = present(env["CBE_OPEN_DATA_SHA256"])

    case env["CBE_LOOKUP_MODE"] || "csv" do
      "csv" -> csv(directory, sha256)
      "indexed" -> %{source: Indexed, source_config: [release_sha256: digest!(sha256)]}
      _ -> raise ArgumentError, "CBE_LOOKUP_MODE must be csv or indexed"
    end
  end

  defp csv(nil, nil), do: %{source: Unconfigured, source_config: []}

  defp csv(directory, sha256) when is_binary(directory) and is_binary(sha256),
    do: %{
      source: OpenData,
      source_config: [directory: directory, release_sha256: digest!(sha256)]
    }

  defp csv(_, _),
    do:
      raise(
        ArgumentError,
        "CBE Open Data requires both CBE_OPEN_DATA_DIRECTORY and CBE_OPEN_DATA_SHA256"
      )

  defp digest!(sha256) do
    unless is_binary(sha256) and Regex.match?(~r/\A[0-9a-fA-F]{64}\z/, sha256) do
      raise ArgumentError, "CBE_OPEN_DATA_SHA256 must be a 64-character SHA-256 digest"
    end

    String.downcase(sha256)
  end

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value
end
