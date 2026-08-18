defmodule BrusselsWtf.Contracts.PostgresTest do
  use ExUnit.Case, async: false

  @moduletag :external

  setup_all do
    url = System.fetch_env!("POSTGRES_CONTRACT_URL")
    expected_database = System.fetch_env!("POSTGRES_CONTRACT_DATABASE")
    expected_role = System.fetch_env!("POSTGRES_CONTRACT_ROLE")
    {:ok, connection} = Postgrex.start_link(url: url)

    on_exit(fn -> GenServer.stop(connection) end)

    {:ok,
     connection: connection, expected_database: expected_database, expected_role: expected_role}
  end

  test "uses the dedicated logical database and application role", context do
    assert [[database, role]] =
             query!(context.connection, "select current_database(), current_user").rows

    assert database == context.expected_database
    assert role == context.expected_role
  end

  test "the application role has no cluster-level powers", %{connection: connection} do
    result =
      query!(connection, """
      select rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls
      from pg_roles
      where rolname = current_user
      """)

    assert result.rows == [[false, false, false, false, false]]
  end

  test "inherited roles and other databases do not grant cluster provisioning rights", %{
    connection: connection
  } do
    inherited_elevated_roles =
      query!(connection, """
      select rolname
      from pg_roles
      where rolname <> current_user
        and pg_has_role(current_user, oid, 'member')
        and (rolsuper or rolcreatedb or rolcreaterole or rolreplication or rolbypassrls)
      """)

    assert inherited_elevated_roles.rows == []

    other_database_create_rights =
      query!(connection, """
      select datname
      from pg_database
      where datname <> current_database()
        and has_database_privilege(current_user, oid, 'CREATE')
      """)

    assert other_database_create_rights.rows == []
  end

  test "every application migration is up", %{connection: connection} do
    expected_versions =
      "priv/repo/migrations/[0-9]*.exs"
      |> Path.wildcard()
      |> Enum.map(fn path -> path |> Path.basename() |> String.split("_", parts: 2) |> hd() end)
      |> MapSet.new()

    migrated_versions =
      connection
      |> query!("select version::text from schema_migrations")
      |> Map.fetch!(:rows)
      |> Enum.map(fn [version] -> version end)
      |> MapSet.new()

    assert MapSet.subset?(expected_versions, migrated_versions)
  end

  test "the role can migrate and write only inside a rolled-back application transaction", %{
    connection: connection
  } do
    table = "storage_contract_#{System.unique_integer([:positive])}"

    assert %Postgrex.Result{command: :begin} = query!(connection, "begin")

    try do
      assert %Postgrex.Result{command: :create_table} =
               query!(connection, "create table #{table} (id bigint primary key)")

      assert %Postgrex.Result{num_rows: 1} = query!(connection, "insert into #{table} values (1)")
      assert query!(connection, "select id from #{table}").rows == [[1]]
    after
      query!(connection, "rollback")
    end
  end

  defp query!(connection, statement), do: Postgrex.query!(connection, statement, [])
end
