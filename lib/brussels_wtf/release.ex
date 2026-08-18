defmodule BrusselsWtf.Release do
  @moduledoc """
  Database tasks for production releases where Mix is unavailable.
  """

  @app :brussels_wtf

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def validate_archive do
    load_app()
    {:ok, _started} = Application.ensure_all_started(:req)

    case Application.fetch_env!(@app, :archive) do
      BrusselsWtf.Archive.S3 ->
        case BrusselsWtf.Archive.S3.validate() do
          :ok -> IO.puts("Source archive validation passed")
          {:error, reason} -> raise "source archive validation failed: #{inspect(reason)}"
        end

      _other ->
        raise "source archive validation failed: archive is not configured"
    end
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)
  defp load_app, do: Application.load(@app)
end
