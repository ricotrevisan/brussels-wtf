defmodule BrusselsWtf.ReleaseCBETest do
  use BrusselsWtf.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias BrusselsWtf.CBE.{Index, Indexed, OpenData, OpenDataFixture, Unconfigured}
  alias BrusselsWtf.Release

  setup do
    directory = OpenDataFixture.write_release()
    manifest = OpenDataFixture.manifest(directory)
    manifest_path = Path.join(directory, "trusted-manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest))

    previous =
      for key <- [Indexed, OpenData, :cbe_source, :process_role],
          do: {key, Application.fetch_env(:brussels_wtf, key)}

    Application.put_env(:brussels_wtf, Indexed, release_sha256: manifest["sha256"])
    Application.put_env(:brussels_wtf, :cbe_source, Indexed)
    Application.put_env(:brussels_wtf, :process_role, :app)

    on_exit(fn ->
      File.rm_rf!(directory)

      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:brussels_wtf, key, value)
          :error -> Application.delete_env(:brussels_wtf, key)
        end
      end
    end)

    %{directory: directory, manifest: manifest, manifest_path: manifest_path}
  end

  test "selected missing and staging indexes fail closed without importing", context do
    assert capture_io(fn ->
             assert_raise RuntimeError, "CBE index readiness validation failed", fn ->
               Release.validate()
             end
           end) == "Database migration validation passed\n"

    assert {:error, :not_found} = Index.status(context.manifest["sha256"])

    assert {:ok, %{state: :staging}} =
             Release.import_cbe_index(context.directory, context.manifest_path, max_batches: 1)

    assert_raise RuntimeError, "CBE index readiness validation failed", fn ->
      Release.validate_cbe_index()
    end
  end

  test "ready exact release validates without its source directory; another selection fails",
       context do
    assert {:ok, %{state: :ready}} =
             Release.import_cbe_index(context.directory, context.manifest_path)

    File.rm_rf!(context.directory)

    assert capture_io(fn -> assert :ok = Release.validate_cbe_index() end) ==
             "CBE index readiness validation passed\n"

    assert {:ok, %{entity: %{registered_name: "Example Brussels, ASBL"}}} =
             Indexed.fetch_enterprise("0123456749")

    Application.put_env(:brussels_wtf, Indexed, release_sha256: String.duplicate("b", 64))

    assert_raise RuntimeError, "CBE index readiness validation failed", fn ->
      Release.validate_cbe_index()
    end
  end

  test "OCR, CSV, and unconfigured initial releases do not depend on the index" do
    Application.put_env(:brussels_wtf, :process_role, :ocr)
    assert :ok = Release.validate_cbe_index()
    Application.put_env(:brussels_wtf, :process_role, :app)

    for source <- [OpenData, Unconfigured] do
      Application.put_env(:brussels_wtf, :cbe_source, source)
      Application.put_env(:brussels_wtf, OpenData, directory: "/not-mounted/private")
      assert :ok = Release.validate_cbe_index()
    end
  end

  test "explicit import resumes and returns only a safe summary without selecting or logging",
       context do
    Application.put_env(:brussels_wtf, :cbe_source, Unconfigured)

    log =
      capture_log(fn ->
        assert capture_io(fn ->
                 assert {:ok, summary} =
                          Release.import_cbe_index(context.directory, context.manifest_path,
                            batch_size: 2,
                            max_batches: 1
                          )

                 assert summary.state == :staging
                 assert summary.rows == 2

                 assert Enum.sort(Map.keys(summary)) ==
                          Enum.sort([
                            :sha256,
                            :state,
                            :projection_version,
                            :progress,
                            :completed_files,
                            :rows
                          ])

                 assert {:ok, %{state: :ready}} =
                          Release.import_cbe_index(context.directory, context.manifest_path)
               end) == ""
      end)

    refute log =~ context.directory
    refute log =~ "Example Brussels"
    refute log =~ "synthetic fixture"
    assert Application.fetch_env!(:brussels_wtf, :cbe_source) == Unconfigured
  end

  test "unreadable, malformed, non-object, and oversized manifests fail without exposing bytes or paths",
       context do
    assert {:error, :invalid_cbe_index_manifest} =
             Release.import_cbe_index(context.directory, context.manifest_path <> "-missing")

    for bytes <- ["", "secret malformed JSON", "[]", "null", String.duplicate(" ", 1_048_577)] do
      File.write!(context.manifest_path, bytes)

      assert {:error, :invalid_cbe_index_manifest} =
               Release.import_cbe_index(context.directory, context.manifest_path)
    end

    assert {:error, :not_found} = Index.status(context.manifest["sha256"])
  end

  test "manifest byte limit is inclusive and backend still checks structure and import limits",
       context do
    json = Jason.encode!(context.manifest)
    File.write!(context.manifest_path, json <> String.duplicate(" ", 1_048_576 - byte_size(json)))

    for options <- [[batch_size: 0], [batch_size: 1001], [max_batches: 0], [unknown: true]] do
      assert {:error, :invalid_limits} =
               Release.import_cbe_index(context.directory, context.manifest_path, options)
    end

    assert {:ok, %{state: :ready}} =
             Release.import_cbe_index(context.directory, context.manifest_path)

    File.write!(context.manifest_path, "{}")

    assert {:error, :invalid_manifest} =
             Release.import_cbe_index(context.directory, context.manifest_path)
  end

  test "cold eval starts index dependencies and Repo, never web or Oban", context do
    config_path = Path.join(context.directory, "eval-config")
    config = Config.Reader.read!("config/config.exs", env: :test, target: :host)

    repo =
      config[:brussels_wtf][BrusselsWtf.Repo] |> Keyword.put(:pool, DBConnection.ConnectionPool)

    app = Keyword.put(config[:brussels_wtf], BrusselsWtf.Repo, repo)
    config = Keyword.put(config, :brussels_wtf, app)
    File.write!(config_path, :erlang.term_to_binary(config))

    code = """
    Application.put_all_env(:erlang.binary_to_term(File.read!(#{inspect(config_path)})))
    {:error, :cbe_source_unavailable} = BrusselsWtf.Release.import_cbe_index(
      #{inspect(context.directory <> "-missing")}, #{inspect(context.manifest_path)})
    Application.put_env(:brussels_wtf, :cbe_source, BrusselsWtf.CBE.Indexed)
    Application.put_env(:brussels_wtf, BrusselsWtf.CBE.Indexed,
      release_sha256: #{inspect(String.duplicate("f", 64))})
    try do
      BrusselsWtf.Release.validate_cbe_index()
      raise "unexpected readiness"
    rescue
      error in RuntimeError ->
        "CBE index readiness validation failed" = Exception.message(error)
    end
    true = Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :ash_postgres end)
    false = Enum.any?(Application.started_applications(), fn {app, _, _} -> app in [:brussels_wtf, :oban] end)
    nil = Process.whereis(BrusselsWtfWeb.Endpoint)
    nil = Process.whereis(BrusselsWtf.Repo)
    IO.puts("cold CBE eval passed")
    """

    paths = Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]))
    args = Enum.flat_map(paths, &["-pa", &1]) ++ ["--eval", code]
    assert {output, 0} = System.cmd("elixir", args, stderr_to_stdout: true)
    assert output =~ "cold CBE eval passed"
    refute output =~ context.directory
    refute output =~ "Example Brussels"
  end
end
