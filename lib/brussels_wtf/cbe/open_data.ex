defmodule BrusselsWtf.CBE.OpenData do
  @moduledoc "Private CSV reader for an operator-provisioned CBE Open Data full release."
  @behaviour BrusselsWtf.CBE

  alias BrusselsWtf.CBE.Source

  @impl true
  def fetch_enterprise(enterprise_number) do
    with {:ok, number} <- Source.normalize_number(enterprise_number),
         {:ok, config} <- configured_release() do
      Source.load(config.directory, config.release_sha256, number)
    end
  end

  defp configured_release do
    config = Application.get_env(:brussels_wtf, __MODULE__, [])
    directory = config[:directory]
    sha256 = config[:release_sha256]

    cond do
      not is_binary(directory) or directory == "" ->
        {:error, :cbe_source_unconfigured}

      not is_binary(sha256) or not Regex.match?(~r/\A[0-9a-f]{64}\z/i, sha256) ->
        {:error, {:invalid_cbe_open_data_release, :invalid_release_sha256}}

      true ->
        {:ok, %{directory: directory, release_sha256: String.downcase(sha256)}}
    end
  end
end
