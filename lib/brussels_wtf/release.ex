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

  @doc "Checks migrations, the selected CBE index, the private archive, and processor safety."
  def validate do
    validate_database()
    validate_cbe_index()
    validate_archive()
    validate_pdf_toolchain()
    validate_transcription_disabled()
  end

  def validate_pdf_toolchain do
    load_app()
    metadata = BrusselsWtf.PDF.Processor.metadata()
    versions = metadata.tool_versions

    required = ["pdfinfo", "pdftotext", "ocrmypdf", "tesseract"]

    if Enum.any?(required, &(versions[&1] in [nil, "", "unavailable"])) or
         not String.contains?(versions["tesseract_languages"] || "", "fra") or
         not String.contains?(versions["tesseract_languages"] || "", "nld") do
      raise "PDF toolchain validation failed"
    end

    IO.puts("PDF toolchain validation passed")
    :ok
  end

  def validate_transcription_disabled do
    load_app()

    if Application.fetch_env!(@app, :automatic_transcription) do
      raise "automatic transcription must remain disabled"
    end

    IO.puts("Automatic transcription is disabled")
    :ok
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

  @doc "Requires the app role's explicitly selected index to be ready; never imports or falls back."
  def validate_cbe_index do
    load_app()

    if Application.get_env(@app, :process_role, :app) != :ocr and
         Application.get_env(@app, :cbe_source) == BrusselsWtf.CBE.Indexed do
      unless with_cbe_repo(fn -> BrusselsWtf.CBE.Indexed.ready?() end) == :ok do
        raise "CBE index readiness validation failed"
      end

      IO.puts("CBE index readiness validation passed")
    end

    :ok
  end

  @doc """
  Explicitly imports a trusted, at-most-1-MiB JSON manifest and private CSV directory.
  Starts only index dependencies and Repo, not the application, web server, or Oban.
  Returns a content-free summary; importing never changes the selected release.
  Options are passed to `BrusselsWtf.CBE.Index.import_release/3`.
  """
  def import_cbe_index(directory, manifest_path, options \\ []) do
    load_app()

    with {:ok, manifest} <- read_cbe_manifest(manifest_path) do
      with_cbe_repo(fn ->
        BrusselsWtf.CBE.Index.import_release(directory, manifest, options)
      end)
    end
  end

  defp read_cbe_manifest(path) do
    # Read one byte beyond the limit rather than allocating an unbounded file.
    case File.open(path, [:read, :binary], fn file -> IO.binread(file, 1_048_577) end) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= 1_048_576 ->
        case Jason.decode(bytes) do
          {:ok, manifest} when is_map(manifest) -> {:ok, manifest}
          _ -> {:error, :invalid_cbe_index_manifest}
        end

      _ ->
        {:error, :invalid_cbe_index_manifest}
    end
  rescue
    _ -> {:error, :invalid_cbe_index_manifest}
  end

  defp with_cbe_repo(fun) do
    with {:ok, _} <- Application.ensure_all_started(:ash_postgres),
         {:ok, result, _} <- Ecto.Migrator.with_repo(BrusselsWtf.Repo, fn _ -> fun.() end) do
      result
    else
      _ -> {:error, :cbe_index_unavailable}
    end
  rescue
    _ -> {:error, :cbe_index_unavailable}
  catch
    :exit, _ -> {:error, :cbe_index_unavailable}
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)
  defp load_app, do: Application.load(@app)
end
