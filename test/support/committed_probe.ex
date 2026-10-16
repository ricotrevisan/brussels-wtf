defmodule BrusselsWtf.CommittedProbe do
  @moduledoc """
  Gives a concurrency probe its own disposable, migrated database.

  Some tests commit rows outside the SQL sandbox so separate connections can
  race on them. Those rows cannot all be deleted again with triggers active:
  `suggestion_review_case_lifecycle` skips every DELETE of a non-suggestion
  review case. Leftovers in the shared test database break unrelated tests,
  so each probe commits into a database of its own, force-dropped when the
  test exits. A failed drop fails the owning test.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias BrusselsWtf.Repo

  @doc """
  Creates and migrates a probe database for the current test.

  Returns a runner: `run.(fun)` executes `fun` on one probe connection, like
  `Ecto.Adapters.SQL.Sandbox.unboxed_run/2` does against the shared database.
  """
  def start! do
    suffix = Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

    config =
      Repo.config()
      |> Keyword.merge(
        database: "#{Repo.config()[:database]}_probe_#{suffix}",
        pool: DBConnection.ConnectionPool,
        pool_size: 6,
        name: nil
      )

    assert :ok = Ecto.Adapters.Postgres.storage_up(config)
    # Repo processes started below stop before on_exit callbacks run.
    on_exit(fn -> drop!(config) end)
    repo = start_supervised!({Repo, config})

    Ecto.Migrator.run(Repo, migrations(), :up,
      all: true,
      dynamic_repo: repo,
      log: false,
      log_migrations_sql: false,
      log_migrator_sql: false
    )

    fn fun -> run(repo, fun) end
  end

  # Compiled once per test run; recompiling redefines every migration module.
  defp migrations do
    with nil <- :persistent_term.get({__MODULE__, :migrations}, nil) do
      migrations =
        for file <- Enum.sort(Path.wildcard(Ecto.Migrator.migrations_path(Repo) <> "/*.exs")),
            {module, _} <- Code.compile_file(file),
            function_exported?(module, :__migration__, 0) do
          [version | _] = String.split(Path.basename(file), "_", parts: 2)
          {String.to_integer(version), module}
        end

      :persistent_term.put({__MODULE__, :migrations}, migrations)
      migrations
    end
  end

  defp run(repo, fun) do
    previous = Repo.put_dynamic_repo(repo)

    try do
      Repo.checkout(fun, timeout: :infinity)
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp drop!(config) do
    assert :ok = Ecto.Adapters.Postgres.storage_down(Keyword.put(config, :force_drop, true))
  end
end
