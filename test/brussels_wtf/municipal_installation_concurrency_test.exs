defmodule BrusselsWtf.MunicipalInstallationConcurrencyTest do
  use ExUnit.Case, async: false

  alias BrusselsWtf.{Identity, Repo}
  alias BrusselsWtf.Identity.MunicipalInstallation

  @moduletag timeout: 120_000

  test "independent publishers serialize different admissions competing for one remaining place" do
    # Unlike the shared-owner sandbox test, these pools have independent PostgreSQL
    # sessions and committed fixtures. Immutable evidence cannot be deleted for cleanup,
    # so use a uniquely named disposable database, never the suite's database.
    database = "installation_cap_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    config =
      Keyword.take(Repo.config(), [:username, :password, :hostname, :port, :ssl, :socket_dir])

    admin = start_supervised!({Postgrex, config ++ [database: "postgres"]})
    Postgrex.query!(admin, ~s(CREATE DATABASE "#{database}"), [])
    # ExUnit stops supervised workers/pools before on_exit, including on test timeout.
    # This fallback covers exits that cannot execute the test process's after block.
    on_exit(fn ->
      {:ok, cleanup} = Postgrex.start_link(config ++ [database: "postgres"])

      try do
        Postgrex.query!(cleanup, ~s|DROP DATABASE IF EXISTS "#{database}" WITH (FORCE)|, [])
      after
        GenServer.stop(cleanup)
      end

      BrusselsWtf.Archive.Memory.reset()
      BrusselsWtf.Processors.Stub.reset()
    end)

    original_repo = Repo.get_dynamic_repo()

    try do
      controller = start_repo!(:cap_controller, database, "cap-controller", 2)
      Repo.put_dynamic_repo(controller)
      assert Repo.query!("SELECT current_database()").rows == [[database]]
      Ecto.Migrator.run(Repo, :up, all: true, log: false, dynamic_repo: controller)

      publisher_a = start_repo!(:cap_a, database, "cap-a", 1)
      publisher_b = start_repo!(:cap_b, database, "cap-b", 1)
      tasks = start_supervised!({Task.Supervisor, []})
      BrusselsWtf.Archive.Memory.reset()
      BrusselsWtf.Processors.Stub.reset()

      # Pin the controller checkout for the session-level barrier and its cleanup.
      Repo.checkout(fn -> exercise_publishers(publisher_a, publisher_b, tasks, database) end,
        timeout: 90_000
      )
    after
      # Stop publishers before closing pools or dropping the database, including when
      # an assertion failed while a task was waiting on a database lock.
      stop_supervised(Task.Supervisor)
      Repo.put_dynamic_repo(original_repo)
      for id <- [:cap_a, :cap_b, :cap_controller], do: stop_supervised(id)
      Postgrex.query!(admin, ~s|DROP DATABASE IF EXISTS "#{database}" WITH (FORCE)|, [])
      BrusselsWtf.Archive.Memory.reset()
      BrusselsWtf.Processors.Stub.reset()
    end

    assert Postgrex.query!(admin, "SELECT datname FROM pg_database WHERE datname = $1", [database]).rows ==
             []

    assert Postgrex.query!(admin, "SELECT pid FROM pg_stat_activity WHERE datname = $1", [
             database
           ]).rows == []
  end

  defp start_repo!(id, database, application_name, pool_size) do
    start_supervised!(
      Supervisor.child_spec(
        {Repo,
         name: nil,
         database: database,
         pool: DBConnection.ConnectionPool,
         pool_size: pool_size,
         parameters: [
           application_name: application_name,
           statement_timeout: "20000",
           lock_timeout: "15000"
         ]},
        id: id
      )
    )
  end

  defp exercise_publishers(publisher_a, publisher_b, tasks, database) do
    commune = BrusselsWtf.MunicipalInstallationArchiveFixture.load!("forest")
    actor = %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}

    assert {:ok, [%{published_new: 1}]} =
             MunicipalInstallation.publish(["forest"], actor: actor, max_facts_per_commune: 1)

    assert public_names() == ["Chloé Exemple"]

    barrier = "installation-test-barrier:#{commune.id}"
    capacity = "municipal-installation-capacity:#{commune.id}"
    [[controller_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
    install_trigger!(barrier)
    Repo.query!("SELECT pg_advisory_lock(hashtextextended($1, 0))", [barrier])

    try do
      task_a = publish_task(tasks, publisher_a, :a, database, actor)
      assert_receive {:publisher_backend, :a, pid_a}, 5_000
      assert pid_a != controller_pid

      # Only C's verification reaches this barrier. B's verification failed and
      # rolled back for cap-a, so A is now spending the one remaining place on C.
      await_lock!(pid_a, barrier, false, [controller_pid])
      assert lock_rows(pid_a, capacity) == [[true, [controller_pid]]]

      task_b = publish_task(tasks, publisher_b, :b, database, actor)
      assert_receive {:publisher_backend, :b, pid_b}, 5_000
      assert pid_b != pid_a
      assert pid_b != controller_pid

      # Assert the exact PostgreSQL wait, not a sleep or task-completion race.
      # Without the commune lock, cap-b could admit B while cap-a is paused on C;
      # their distinct people/facts cannot be serialized by person uniqueness.
      await_lock!(pid_b, capacity, false, [pid_a])
      assert public_names() == ["Chloé Exemple"]
      assert Task.yield(task_b, 0) == nil

      assert Repo.query!("SELECT pg_advisory_unlock(hashtextextended($1, 0))", [barrier]).rows ==
               [[true]]

      assert {:ok,
              [%{published_new: 1, published_existing: 1, rejected: [%{reason: :database_error}]}]} =
               Task.await(task_a, 20_000)

      assert {:ok, [%{published_new: 0, published_existing: 2, rejected: []}]} =
               Task.await(task_b, 20_000)

      assert public_names() == ["Chloé Exemple", "Zoé Autre"]
      assert Ash.count!(Identity.Person) == 2

      assert Repo.query!(
               "SELECT count(*) FROM sourced_facts WHERE verified_by = 'municipal_installation_v1' AND verification_status = 'verified'"
             ).rows == [[2]]

      assert Repo.query!(
               "SELECT count(*) FROM sourced_fact_verification_events WHERE verifier_id = 'municipal_installation_v1'"
             ).rows == [[2]]

      assert lock_rows(pid_a, capacity) == []
      assert lock_rows(pid_b, capacity) == []
      assert lock_rows(pid_a, barrier) == []
    after
      Repo.query!("SELECT pg_advisory_unlock(hashtextextended($1, 0))", [barrier])
    end
  end

  defp install_trigger!(barrier) do
    # Fault injection is confined to the disposable test DB. Trigger the raw SQL
    # verification transition, not an Ash create error with different wrapping.
    Repo.query!("""
    CREATE FUNCTION test_installation_capacity_race() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE person_name text;
    BEGIN
      IF current_setting('application_name') = 'cap-a' AND NEW.verification_status = 'verified' THEN
        SELECT legal_name INTO person_name FROM people WHERE id = NEW.subject_id;
        IF person_name = 'Jean-Louis Test' THEN
          RAISE EXCEPTION 'test-only B admission failure';
        ELSIF person_name = 'Zoé Autre' THEN
          PERFORM pg_advisory_xact_lock(hashtextextended('#{barrier}', 0));
        END IF;
      END IF;
      RETURN NEW;
    END; $$;
    """)

    Repo.query!("""
    CREATE TRIGGER test_installation_capacity_race BEFORE UPDATE ON sourced_facts
    FOR EACH ROW EXECUTE FUNCTION test_installation_capacity_race()
    """)
  end

  defp publish_task(supervisor, repo, label, database, actor) do
    parent = self()

    Task.Supervisor.async_nolink(supervisor, fn ->
      Repo.put_dynamic_repo(repo)
      assert [[pid, ^database]] = Repo.query!("SELECT pg_backend_pid(), current_database()").rows
      send(parent, {:publisher_backend, label, pid})
      MunicipalInstallation.publish(["forest"], actor: actor, max_facts_per_commune: 2)
    end)
  end

  defp public_names do
    Identity.list_public_relationships!() |> Enum.map(& &1.subject_name) |> Enum.sort()
  end

  defp lock_rows(pid, key) do
    Repo.query!(
      """
      SELECT granted, pg_blocking_pids(pid) FROM pg_locks
      WHERE locktype = 'advisory' AND pid = $1 AND objsubid = 1
        AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
        AND classid = ((hashtextextended($2, 0) >> 32) & 4294967295)::oid
        AND objid = (hashtextextended($2, 0) & 4294967295)::oid
      """,
      [pid, key]
    ).rows
  end

  defp await_lock!(pid, key, granted, blockers) do
    wait_for_lock!(pid, key, [[granted, blockers]], System.monotonic_time(:millisecond) + 5_000)
  end

  defp wait_for_lock!(pid, key, expected, deadline) do
    rows = lock_rows(pid, key)

    if rows == expected do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "backend #{pid} never reached expected advisory wait: #{inspect(rows)}"

      Process.sleep(20)
      wait_for_lock!(pid, key, expected, deadline)
    end
  end
end
