defmodule BrusselsWtf.CBE.IndexConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias BrusselsWtf.CBE.{Index, OpenDataFixture}
  alias BrusselsWtf.Repo
  alias Ecto.Adapters.SQL.Sandbox

  test "competing importers cannot overwrite checkpoints or duplicate source ordinals" do
    directory = OpenDataFixture.write_release() |> OpenDataFixture.add_enterprises(100)
    sha = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    manifest = OpenDataFixture.manifest(directory, sha)

    try do
      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, %{state: :staging}} =
                 Index.import_release(directory, manifest, max_batches: 1)

        tasks =
          for _ <- 1..2 do
            Task.async(fn ->
              receive do: (:start -> :ok)

              Sandbox.unboxed_run(Repo, fn ->
                Index.import_release(directory, manifest, batch_size: 2)
              end)
            end)
          end

        Enum.each(tasks, &send(&1.pid, :start))
        results = Enum.map(tasks, &Task.await(&1, 30_000))
        assert Enum.any?(results, &match?({:ok, %{state: :ready}}, &1))

        assert Enum.all?(
                 results,
                 &(match?({:ok, %{state: :ready}}, &1) or &1 == {:error, :concurrent_import})
               )

        assert {:ok, summary} = Index.import_release(directory, manifest)
        assert summary.rows == 118
        assert summary.progress["enterprise.csv"] == 102
        assert {:ok, bundle} = Index.fetch_enterprise(sha, "0123456749")
        assert length(bundle.names) == 3
        assert length(bundle.establishment_units) == 1
      end)
    after
      File.rm_rf!(directory)

      Sandbox.unboxed_run(Repo, fn ->
        ids =
          Repo.all(from(r in "cbe_index_releases", where: r.sha256 == ^sha, select: r.id),
            log: false
          )

        Repo.delete_all(from(e in "cbe_index_entries", where: e.release_id in ^ids), log: false)
        Repo.delete_all(from(r in "cbe_index_releases", where: r.sha256 == ^sha), log: false)
      end)
    end
  end
end
