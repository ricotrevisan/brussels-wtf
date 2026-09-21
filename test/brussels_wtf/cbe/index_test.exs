defmodule BrusselsWtf.CBE.IndexTest do
  use BrusselsWtf.DataCase, async: false

  alias BrusselsWtf.CBE.{Index, Indexed, OpenData, OpenDataFixture}

  setup do
    directory = OpenDataFixture.write_release()
    manifest = OpenDataFixture.manifest(directory)

    previous =
      for key <- [OpenData, Indexed, :cbe_source],
          do: {key, Application.get_env(:brussels_wtf, key)}

    Application.put_env(:brussels_wtf, OpenData,
      directory: directory,
      release_sha256: manifest["sha256"]
    )

    Application.put_env(:brussels_wtf, Indexed, release_sha256: manifest["sha256"])
    Application.put_env(:brussels_wtf, :cbe_source, Indexed)

    on_exit(fn ->
      File.rm_rf!(directory)

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:brussels_wtf, key, value),
          else: Application.delete_env(:brussels_wtf, key)
      end
    end)

    %{directory: directory, manifest: manifest}
  end

  test "edge cases preserve source order, first names, duplicates, and juridical-form typing", %{
    directory: directory
  } do
    OpenDataFixture.add_edge_cases(directory)
    manifest = OpenDataFixture.manifest(directory)
    numbers = ["0123456749", "0474521921", "0000000001", "0000000002", "9999999999", "bad", nil]
    expected = Map.new(numbers, &{&1, OpenData.fetch_enterprise(&1)})
    assert {:ok, %{state: :ready}} = Index.import_release(directory, manifest, batch_size: 2)
    File.rm_rf!(directory)

    for {number, result} <- expected,
        do: assert(BrusselsWtf.CBE.fetch_enterprise(number) == result)

    assert {:ok, bundle} = Indexed.fetch_enterprise("0123456749")
    assert bundle.entity.registered_name == "Example Brussels, ASBL"

    assert Enum.map(bundle.establishment_units, & &1.unit_number) == [
             "2123456789",
             "2000000001",
             "2123456789"
           ]

    assert Enum.at(bundle.establishment_units, 1).name == nil
    assert Enum.at(bundle.establishment_units, 1).started_on == nil
    assert Enum.at(bundle.names, 3).name == "Duplicate registered\nwith \"quotes\""
    assert Enum.at(bundle.names, 3).language == "99"

    assert {:ok, %{entity: %{status: :inactive, entity_type: :legal_person}}} =
             Indexed.fetch_enterprise("0000000001")

    assert {:error, {:invalid_cbe_open_data_release, :registered_name_missing}} =
             Indexed.fetch_enterprise("0000000002")
  end

  test "bounded imports resume at logical row checkpoints and remain hidden until ready", %{
    directory: directory,
    manifest: manifest
  } do
    OpenDataFixture.add_edge_cases(directory)
    manifest = OpenDataFixture.manifest(directory, manifest["sha256"])
    assert {:ok, first} = Index.import_release(directory, manifest, batch_size: 2, max_batches: 1)
    assert first.state == :staging
    assert first.progress == %{"meta.csv" => 2}
    assert first.rows == 2
    assert {:error, :cbe_index_not_ready} = Indexed.fetch_enterprise("0123456749")
    assert {:error, :cbe_index_not_ready} = Indexed.ready?()

    # Deliberately tiny interruption stress test, not an operational import loop:
    # each invocation rehashes inputs and replays the current file's prefix.
    final =
      Enum.reduce_while(1..30, first, fn _, previous ->
        assert {:ok, next} =
                 Index.import_release(directory, manifest, batch_size: 2, max_batches: 1)

        assert next.rows >= previous.rows
        assert next.rows <= previous.rows + 2
        if next.state == :ready, do: {:halt, next}, else: {:cont, next}
      end)

    assert final.state == :ready

    assert final.progress == %{
             "meta.csv" => 5,
             "code.csv" => 5,
             "enterprise.csv" => 5,
             "establishment.csv" => 3,
             "denomination.csv" => 8
           }

    assert {:ok, ^final} = Index.import_release(directory, manifest)
    assert {:ok, ^final} = Index.status(manifest["sha256"])
    assert Indexed.fetch_enterprise("0123456749") == OpenData.fetch_enterprise("0123456749")
  end

  test "max_batches budgets the whole invocation across files, not each file", %{
    directory: directory
  } do
    OpenDataFixture.add_edge_cases(directory)
    manifest = OpenDataFixture.manifest(directory)

    # Three metadata batches plus one code batch exhaust this invocation.
    assert {:ok, first} = Index.import_release(directory, manifest, batch_size: 2, max_batches: 4)
    assert first.progress == %{"meta.csv" => 5, "code.csv" => 2}
    assert first.completed_files == ["meta.csv"]
    assert first.rows == 7

    # Resume replays/verifies the two committed code rows once, then imports
    # two code batches and two enterprise batches within the same budget.
    assert {:ok, second} =
             Index.import_release(directory, manifest, batch_size: 2, max_batches: 4)

    assert second.progress == %{"meta.csv" => 5, "code.csv" => 5, "enterprise.csv" => 4}
    assert second.completed_files == ["meta.csv", "code.csv"]
    assert second.rows == 14

    assert {:ok, %{state: :ready, rows: 26}} =
             Index.import_release(directory, manifest, batch_size: 2, max_batches: 20)

    assert {:ok, bundle} = Indexed.fetch_enterprise("0123456749")
    assert Enum.at(bundle.names, 3).name == "Duplicate registered\nwith \"quotes\""
  end

  test "an incompatible projection cannot reuse an archive identity", %{
    directory: directory,
    manifest: manifest
  } do
    BrusselsWtf.CBE.Index.Release
    |> Ash.Changeset.for_create(:stage, %{
      sha256: manifest["sha256"],
      manifest: manifest,
      projection_version: 0
    })
    |> Ash.create!()

    assert {:error, :release_manifest_conflict} = Index.import_release(directory, manifest)
    assert {:error, :cbe_index_not_ready} = Indexed.ready?()
  end

  test "only valid full-release metadata can seal", %{directory: directory, manifest: manifest} do
    path = Path.join(directory, "meta.csv")
    File.write!(path, String.replace(File.read!(path), "ExtractType,Full", "ExtractType,Delta"))
    manifest = OpenDataFixture.manifest(directory, manifest["sha256"])

    assert {:error, {:invalid_cbe_open_data_release, :full_release_required}} =
             Index.import_release(directory, manifest)

    assert {:ok, %{state: :staging}} = Index.status(manifest["sha256"])
    assert {:error, :cbe_index_not_ready} = Indexed.ready?()
  end

  test "changed bytes or manifests cannot stage, resume, or replace an immutable release", %{
    directory: directory,
    manifest: manifest
  } do
    path = Path.join(directory, "denomination.csv")
    original = File.read!(path)
    File.write!(path, original <> "secret corrupted row\n")
    assert {:error, :manifest_mismatch} = Index.import_release(directory, manifest)
    assert {:error, :not_found} = Index.status(manifest["sha256"])
    File.write!(path, original)
    assert {:ok, staging} = Index.import_release(directory, manifest, max_batches: 1)
    File.write!(path, String.replace(original, "Example Trading", "Different Trading"))
    assert {:error, :manifest_mismatch} = Index.import_release(directory, manifest)
    changed_manifest = OpenDataFixture.manifest(directory)

    assert {:error, :release_manifest_conflict} =
             Index.import_release(directory, changed_manifest)

    assert {:ok, ^staging} = Index.status(manifest["sha256"])
    File.write!(path, original)
    assert {:ok, ready} = Index.import_release(directory, manifest)
    changed_metadata = put_in(manifest, ["metadata", "source"], "different origin")

    assert {:error, :release_manifest_conflict} =
             Index.import_release(directory, changed_metadata)

    assert {:ok, ^ready} = Index.status(manifest["sha256"])
  end

  test "selection is exact and switching or rolling back keeps each bundle coherent", %{
    directory: directory,
    manifest: first
  } do
    assert {:ok, _} = Index.import_release(directory, first)
    assert {:ok, old} = Indexed.fetch_enterprise("0123456749")
    path = Path.join(directory, "denomination.csv")
    File.write!(path, String.replace(File.read!(path), "Example", "Replacement"))
    second = OpenDataFixture.manifest(directory, String.duplicate("b", 64))
    assert {:ok, %{state: :ready}} = Index.import_release(directory, second)
    assert {:ok, ^old} = Indexed.fetch_enterprise("0123456749")
    File.rm_rf!(directory)
    Application.put_env(:brussels_wtf, Indexed, release_sha256: second["sha256"])
    assert {:ok, new} = Indexed.fetch_enterprise("0123456749")
    assert new.release.sha256 == second["sha256"]
    assert new.entity.registered_name == "Replacement Brussels, ASBL"
    assert hd(new.establishment_units).name == "Replacement Brussels Unit"
    Application.put_env(:brussels_wtf, Indexed, release_sha256: String.duplicate("c", 64))
    assert {:error, :cbe_index_not_ready} = Indexed.fetch_enterprise("0123456749")
    Application.put_env(:brussels_wtf, Indexed, release_sha256: first["sha256"])
    assert {:ok, ^old} = Indexed.fetch_enterprise("0123456749")
  end

  test "limits and parse failures are bounded, sanitized, and never make staging readable", %{
    directory: directory,
    manifest: manifest
  } do
    for opts <- [
          [batch_size: 0],
          [batch_size: 1001],
          [max_batches: 0],
          [max_record_bytes: 0],
          [max_batch_bytes: 0],
          [unknown: 1],
          %{}
        ] do
      assert {:error, :invalid_limits} = Index.import_release(directory, manifest, opts)
    end

    assert {:error, :not_found} = Index.status(manifest["sha256"])

    assert {:error, {:invalid_cbe_open_data_release, :record_too_large}} =
             Index.import_release(directory, manifest, max_record_bytes: 8)

    assert {:ok, %{state: :staging, rows: 0}} = Index.status(manifest["sha256"])
    assert {:ok, %{state: :ready}} = Index.import_release(directory, manifest)
  end

  test "SQL debug logs and operational errors do not expose private rows", %{
    directory: directory,
    manifest: manifest
  } do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        Repo.query!("SELECT $1::text", ["privacy log canary"])
        assert {:ok, _} = Index.import_release(directory, manifest)
        assert {:ok, _} = Indexed.fetch_enterprise("0474521921")
      end)

    assert log =~ "privacy log canary"
    refute log =~ "Example Natural"
    refute log =~ "cbe_index_entries"
    refute log =~ "0474521921"
  end

  test "a file changed during a bounded invocation cannot contaminate a later ready release", %{
    directory: directory,
    manifest: manifest
  } do
    OpenDataFixture.add_enterprises(directory, 3000)
    manifest = OpenDataFixture.manifest(directory, manifest["sha256"])
    path = Path.join(directory, "enterprise.csv")
    original = File.read!(path)
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(id, [:brussels_wtf, :repo, :query], &__MODULE__.mutate_fixture/4, %{
        owner: self(),
        id: id,
        path: path,
        original: original
      })

    try do
      assert {:ok, staging} = Index.import_release(directory, manifest, max_batches: 3)
      assert staging.progress["enterprise.csv"] == 1000
      assert File.read!(path) != original
      File.write!(path, original)
      assert {:error, :checkpoint_mismatch} = Index.import_release(directory, manifest)
      assert {:ok, ^staging} = Index.status(manifest["sha256"])
      assert {:error, :cbe_index_not_ready} = Indexed.ready?()
    after
      :telemetry.detach(id)
    end
  end

  @doc false
  def mutate_fixture(_event, _measurements, metadata, config) do
    if self() == config.owner and Process.get(config.id) != true and
         String.contains?(metadata.query, "INSERT INTO \"cbe_index_entries\"") do
      Process.put(config.id, true)
      File.write!(config.path, String.replace(config.original, ",AC,", ",ST,"))
    end
  end

  @tag timeout: 60_000
  test "a synthetic 10k import uses bounded batches and indexed lookups", %{
    directory: directory,
    manifest: manifest
  } do
    OpenDataFixture.add_enterprises(directory, 10_000)
    manifest = OpenDataFixture.manifest(directory, manifest["sha256"])
    {microseconds, result} = :timer.tc(fn -> Index.import_release(directory, manifest) end)
    assert {:ok, %{state: :ready, rows: 10_018}} = result

    {lookup_microseconds, _} =
      :timer.tc(fn ->
        for _ <- 1..20, do: assert({:ok, _} = Indexed.fetch_enterprise("0123456749"))
      end)

    IO.puts(
      "Synthetic CBE: 10k import #{Float.round(microseconds / 1_000_000, 3)}s; lookup mean #{Float.round(lookup_microseconds / 20_000, 2)}ms"
    )
  end

  test "a pinned ready release matches the complete CSV bundle without source files", %{
    directory: directory,
    manifest: manifest
  } do
    expected =
      for number <- ["0123.456.749", "0474521921", "0123456789", "bad"],
          into: %{},
          do: {number, OpenData.fetch_enterprise(number)}

    assert {:error, :cbe_index_not_ready} = Indexed.ready?()
    assert {:ok, %{state: :ready}} = Index.import_release(directory, manifest)
    assert :ok = Indexed.ready?()
    assert {:ok, %{state: :ready}} = Index.status(manifest["sha256"])
    File.rm_rf!(directory)

    for {number, result} <- expected,
        do: assert(BrusselsWtf.CBE.fetch_enterprise(number) == result)
  end
end
