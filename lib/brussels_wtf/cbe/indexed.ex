defmodule BrusselsWtf.CBE.Indexed do
  @moduledoc "CBE adapter pinned to a ready PostgreSQL index release, with no CSV fallback."
  @behaviour BrusselsWtf.CBE
  alias BrusselsWtf.CBE.{Index, Source}

  @impl true
  def fetch_enterprise(enterprise_number) do
    with {:ok, number} <- Source.normalize_number(enterprise_number),
         {:ok, sha256} <- selected_release() do
      Index.fetch_enterprise(sha256, number)
    end
  end

  @doc "Checks the configured exact release without reading files or importing data."
  def ready? do
    with {:ok, sha256} <- selected_release(), do: Index.ready?(sha256)
  end

  defp selected_release do
    case Application.get_env(:brussels_wtf, __MODULE__, [])[:release_sha256] do
      nil ->
        {:error, :cbe_source_unconfigured}

      sha256 when is_binary(sha256) ->
        sha256 = String.downcase(sha256)

        if BrusselsWtf.CBE.Index.Manifest.valid_sha?(sha256),
          do: {:ok, sha256},
          else: {:error, :invalid_release_sha256}

      _ ->
        {:error, :invalid_release_sha256}
    end
  end
end
