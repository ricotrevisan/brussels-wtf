defmodule BrusselsWtf.Release do
  @moduledoc """
  Database and storage validation for production releases where Mix is unavailable.
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

  @doc "Fails the release unless every migration is up and the private archive contract passes."
  def validate do
    validate_database()
    validate_archive()
  end

  def validate_database(options \\ []) do
    load_app()
    database_check = Keyword.get(options, :database_check, &BrusselsWtf.Readiness.database/1)

    result =
      Enum.reduce_while(repos(), :ok, fn repo, :ok ->
        case Ecto.Migrator.with_repo(repo, database_check) do
          {:ok, :ok, _started} -> {:cont, :ok}
          {:ok, {:error, :pending_migrations}, _started} -> {:halt, {:error, :pending_migrations}}
          _other -> {:halt, {:error, :database_unavailable}}
        end
      end)

    case result do
      :ok ->
        IO.puts("Database migration validation passed")
        :ok

      {:error, :pending_migrations} ->
        raise "database migration validation failed: migrations are pending"

      {:error, :database_unavailable} ->
        raise "database migration validation failed"
    end
  end

  def validate_archive do
    load_app()
    {:ok, _started} = Application.ensure_all_started(:req)

    result =
      case Application.fetch_env!(@app, :archive) do
        BrusselsWtf.Archive.S3 ->
          BrusselsWtf.Archive.S3.validate()

        _other ->
          {:error, :archive_unavailable}
      end

    case result do
      :ok ->
        IO.puts("Source archive validation passed")
        :ok

      {:error, _reason} ->
        raise "source archive validation failed"
    end
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)
  defp load_app, do: Application.load(@app)
end
