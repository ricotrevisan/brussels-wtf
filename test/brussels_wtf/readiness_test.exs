defmodule BrusselsWtf.ReadinessTest do
  use BrusselsWtf.DataCase, async: false

  alias BrusselsWtf.Readiness

  test "the configured database has no pending migrations" do
    assert :ok = Readiness.database()
  end

  test "the configured archive is accessible" do
    assert :ok = Readiness.archive()
  end

  test "checks the archive only after the database is current" do
    parent = self()

    assert {:error, :pending_migrations} =
             Readiness.check(
               database: fn -> {:error, :pending_migrations} end,
               archive: fn -> send(parent, :archive_checked) end
             )

    refute_received :archive_checked
  end

  test "normalizes unexpected failures without exposing their details" do
    assert {:error, :database_unavailable} =
             Readiness.check(
               database: fn -> raise "ecto://user:secret@private-db/app" end,
               archive: fn -> :ok end
             )
  end
end
