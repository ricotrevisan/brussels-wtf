defmodule BrusselsWtf.ReleaseTest do
  use BrusselsWtf.DataCase, async: false

  import ExUnit.CaptureIO

  alias BrusselsWtf.Release

  test "release validation checks that every database migration is up" do
    assert capture_io(fn -> assert :ok = Release.validate_database() end) ==
             "Database migration validation passed\n"
  end

  test "release validation fails safely when a migration is pending" do
    migrations =
      Path.join(System.tmp_dir!(), "brussels-wtf-pending-#{System.unique_integer([:positive])}")

    File.mkdir_p!(migrations)
    on_exit(fn -> File.rm_rf!(migrations) end)

    File.write!(
      Path.join(migrations, "99999999999999_contract_pending.exs"),
      "defmodule BrusselsWtf.Repo.Migrations.ContractPending do\nend\n"
    )

    error =
      assert_raise RuntimeError, fn ->
        Release.validate_database(database_check: &BrusselsWtf.Readiness.database(&1, migrations))
      end

    assert Exception.message(error) ==
             "database migration validation failed: migrations are pending"

    refute Exception.message(error) =~ "contract_pending"
  end

  test "archive validation fails closed without exposing adapter details" do
    previous = Application.fetch_env!(:brussels_wtf, :archive)
    Application.put_env(:brussels_wtf, :archive, BrusselsWtf.Archive.Unconfigured)

    on_exit(fn -> Application.put_env(:brussels_wtf, :archive, previous) end)

    error = assert_raise RuntimeError, fn -> Release.validate_archive() end
    assert Exception.message(error) == "source archive validation failed"
  end
end
