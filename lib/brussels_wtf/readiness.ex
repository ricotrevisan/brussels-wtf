defmodule BrusselsWtf.Readiness do
  @moduledoc """
  Sanitized database and source-archive checks shared by release validation and
  the runtime readiness monitor.
  """

  alias BrusselsWtf.Archive
  alias BrusselsWtf.Repo

  @spec check(keyword()) ::
          :ok | {:error, :pending_migrations | :database_unavailable | :archive_unavailable}
  def check(options \\ []) do
    database_check = Keyword.get(options, :database, &database/0)
    archive_check = Keyword.get(options, :archive, &archive/0)

    with :ok <- safely(database_check, :database_unavailable),
         :ok <- safely(archive_check, :archive_unavailable) do
      :ok
    end
  end

  @spec database(module(), nil | String.t() | [String.t()]) ::
          :ok | {:error, :pending_migrations | :database_unavailable}
  def database(repo \\ Repo, directories \\ nil) do
    migrations =
      if directories do
        Ecto.Migrator.migrations(repo, directories)
      else
        Ecto.Migrator.migrations(repo)
      end

    if Enum.any?(migrations, &match?({:down, _, _}, &1)) do
      {:error, :pending_migrations}
    else
      :ok
    end
  rescue
    _exception -> {:error, :database_unavailable}
  catch
    _kind, _reason -> {:error, :database_unavailable}
  end

  @spec archive() :: :ok | {:error, :archive_unavailable}
  def archive do
    case Archive.ready?() do
      :ok -> :ok
      {:error, _reason} -> {:error, :archive_unavailable}
    end
  rescue
    _exception -> {:error, :archive_unavailable}
  catch
    _kind, _reason -> {:error, :archive_unavailable}
  end

  defp safely(check, failure) do
    case check.() do
      :ok ->
        :ok

      {:error, reason}
      when reason in [:pending_migrations, :database_unavailable, :archive_unavailable] ->
        {:error, reason}

      _other ->
        {:error, failure}
    end
  rescue
    _exception -> {:error, failure}
  catch
    _kind, _reason -> {:error, failure}
  end
end
