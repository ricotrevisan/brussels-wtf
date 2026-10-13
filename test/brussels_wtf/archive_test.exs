defmodule BrusselsWtf.ArchiveTest do
  use ExUnit.Case, async: false

  defmodule CorruptArchive do
    @behaviour BrusselsWtf.Archive
    def put(namespace, sha256, _bytes),
      do: {:ok, BrusselsWtf.Archive.object_key(sha256, namespace)}

    def put_file(namespace, sha256, _path, _size),
      do: {:ok, BrusselsWtf.Archive.object_key(sha256, namespace)}

    def verify_file(_key, _sha256, _size), do: {:error, :verification_failed}
    def get(_key), do: {:ok, "different bytes"}
    def ready?, do: :ok
    def fetch_file(_key, _hash, _size, _destination, _opts), do: {:error, :verification_failed}
  end

  setup do
    previous = Application.fetch_env!(:brussels_wtf, :archive)
    on_exit(fn -> Application.put_env(:brussels_wtf, :archive, previous) end)
  end

  test "a source write is readable and hash-verified before it is accepted" do
    Application.put_env(:brussels_wtf, :archive, BrusselsWtf.Archive.Memory)
    bytes = "captured authoritative bytes"
    sha256 = "fb51305de88c7c4357f2f0320a14edd140ee4501adc9af234123dc5569c71c2a"

    assert {:ok, %{sha256: ^sha256, object_key: object_key}} =
             BrusselsWtf.Archive.store(bytes)

    assert object_key == "raw/sha256/fb/#{sha256}"
    assert {:ok, ^bytes} = BrusselsWtf.Archive.get(object_key)
  end

  test "a corrupt read-after-write is rejected" do
    Application.put_env(:brussels_wtf, :archive, CorruptArchive)

    assert {:error, {:hash_mismatch, expected, actual}} =
             BrusselsWtf.Archive.store("captured authoritative bytes")

    assert expected != actual
  end

  test "file acceptance derives hash and size and keeps the caller's file" do
    Application.put_env(:brussels_wtf, :archive, BrusselsWtf.Archive.Memory)
    path = source_file("captured authoritative bytes")
    sha256 = BrusselsWtf.Digest.sha256("captured authoritative bytes")

    assert {:ok, %{sha256: ^sha256, byte_size: 28, object_key: object_key}} =
             BrusselsWtf.Archive.store_file(path)

    assert object_key == BrusselsWtf.Archive.object_key(sha256)
    assert File.read!(path) == "captured authoritative bytes"
    assert {:ok, %{object_key: ^object_key}} = BrusselsWtf.Archive.store_file(path)

    assert {:ok, %{object_key: "derived/" <> _}} =
             BrusselsWtf.Archive.store_file(path, :derived)
  end

  test "an empty file has a verified empty snapshot" do
    Application.put_env(:brussels_wtf, :archive, BrusselsWtf.Archive.Memory)
    path = source_file("")
    sha256 = BrusselsWtf.Digest.sha256("")
    assert {:ok, %{sha256: ^sha256, byte_size: 0}} = BrusselsWtf.Archive.store_file(path)
  end

  test "file acceptance requires backend verification, not the binary get path" do
    Application.put_env(:brussels_wtf, :archive, CorruptArchive)
    path = source_file("evidence")
    assert {:error, :verification_failed} = BrusselsWtf.Archive.store_file(path)
  end

  test "an unreadable source file is not accepted" do
    Application.put_env(:brussels_wtf, :archive, BrusselsWtf.Archive.Memory)
    path = source_file("evidence")
    File.rm!(path)
    assert {:error, {:file_read, :enoent}} = BrusselsWtf.Archive.store_file(path)
  end

  test "fetch_file returns immutable metadata and a private verified caller-owned file" do
    Application.put_env(:brussels_wtf, :archive, BrusselsWtf.Archive.Memory)
    bytes = "synthetic archive snapshot"
    {:ok, %{object_key: key, sha256: hash}} = BrusselsWtf.Archive.store(bytes)
    path = fetch_destination()

    assert {:ok, %{object_key: ^key, sha256: ^hash, byte_size: 26}} =
             BrusselsWtf.Archive.fetch_file(key, hash, 26, path, max_bytes: 30)

    assert File.read!(path) == bytes
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
  end

  test "fetch_file rejects invalid identity and limits before any backend read or destination creation" do
    Application.put_env(:brussels_wtf, :archive, BrusselsWtf.Archive.Memory)
    hash = BrusselsWtf.Digest.sha256("snapshot")
    key = BrusselsWtf.Archive.object_key(hash)
    path = fetch_destination()

    for {key, hash, size, opts, reason} <- [
          {key, hash, 8, [], :invalid_max_bytes},
          {key, hash, 8, [max_bytes: 0], :invalid_max_bytes},
          {key, hash, 8, [max_bytes: -1], :invalid_max_bytes},
          {key, hash, 8, [max_bytes: "9"], :invalid_max_bytes},
          {key, hash, 8, [max_bytes: 7], :max_bytes_exceeded},
          {key, hash, -1, [max_bytes: 9], :invalid_size},
          {key, "bad", 8, [max_bytes: 9], :invalid_sha256},
          {"raw/sha256/ff/#{hash}", hash, 8, [max_bytes: 9], :invalid_object_key},
          {key, String.duplicate("0", 64), 8, [max_bytes: 9], :invalid_object_key},
          {key, hash, 8, [max_bytes: 9, timeout_ms: 0], :invalid_timeout},
          {key, hash, 8, [max_bytes: 9, receive_timeout_ms: :infinity], :invalid_timeout}
        ] do
      assert {:error, ^reason} = BrusselsWtf.Archive.fetch_file(key, hash, size, path, opts)
      refute File.exists?(path)
    end
  end

  test "fetch_file refuses a nonprivate destination directory before reading" do
    Application.put_env(:brussels_wtf, :archive, BrusselsWtf.Archive.Memory)
    {:ok, %{sha256: hash, object_key: key}} = BrusselsWtf.Archive.store("snapshot")
    path = fetch_destination()
    File.chmod!(Path.dirname(path), 0o755)

    assert {:error, :invalid_destination_directory} =
             BrusselsWtf.Archive.fetch_file(key, hash, 8, path, max_bytes: 9)

    refute File.exists?(path)
  end

  test "unconfigured fetch_file fails safely without creating a destination" do
    path = fetch_destination()
    hash = BrusselsWtf.Digest.sha256("snapshot")

    assert {:error, :source_archive_not_configured} =
             BrusselsWtf.Archive.Unconfigured.fetch_file(
               BrusselsWtf.Archive.object_key(hash),
               hash,
               8,
               path,
               max_bytes: 9
             )

    refute File.exists?(path)
  end

  test "fetch_file preserves existing files and symlinks without reading the archive" do
    Application.put_env(:brussels_wtf, :archive, BrusselsWtf.Archive.Memory)
    hash = BrusselsWtf.Digest.sha256("missing")
    key = BrusselsWtf.Archive.object_key(hash)
    path = fetch_destination()
    File.write!(path, "caller data")

    assert {:error, {:destination, :eexist}} =
             BrusselsWtf.Archive.fetch_file(key, hash, 7, path, max_bytes: 9)

    assert File.read!(path) == "caller data"
    link = path <> "-link"
    File.ln_s!(path, link)

    assert {:error, {:destination, :eexist}} =
             BrusselsWtf.Archive.fetch_file(key, hash, 7, link, max_bytes: 9)

    assert File.read_link!(link) == path
    assert File.read!(path) == "caller data"
    File.rm!(path)

    assert {:error, {:destination, :eexist}} =
             BrusselsWtf.Archive.fetch_file(key, hash, 7, link, max_bytes: 9)

    assert File.read_link!(link) == path
  end

  test "Memory fetch checks real fixture bytes and cleans failures" do
    alias BrusselsWtf.Archive
    alias BrusselsWtf.Archive.Memory
    hash = BrusselsWtf.Digest.sha256("source")
    key = Archive.object_key(hash)

    for {bytes, size, error} <- [
          {"others", 6, {:hash_mismatch, hash, BrusselsWtf.Digest.sha256("others")}},
          {"sou", 6, {:size_mismatch, 6, 3}},
          {"source extra", 6, {:size_mismatch, 6, 12}}
        ] do
      Agent.update(Memory, &Map.put(&1, key, bytes))
      path = fetch_destination()
      assert {:error, ^error} = Memory.fetch_file(key, hash, size, path, max_bytes: 9)
      refute File.exists?(path)
    end

    path = fetch_destination()
    missing = String.duplicate("0", 64)

    assert {:error, :not_found} =
             Memory.fetch_file(Archive.object_key(missing), missing, 6, path, max_bytes: 9)

    refute File.exists?(path)
  end

  test "fetch_file accepts a zero-byte snapshot with a positive explicit cap" do
    alias BrusselsWtf.Archive
    Application.put_env(:brussels_wtf, :archive, Archive.Memory)
    {:ok, %{sha256: hash, object_key: key}} = Archive.store("")
    path = fetch_destination()

    assert {:ok, %{sha256: ^hash, object_key: ^key, byte_size: 0}} =
             Archive.fetch_file(key, hash, 0, path, max_bytes: 1)

    assert File.read!(path) == ""
  end

  defp fetch_destination do
    dir = Path.join(System.tmp_dir!(), "archive-fetch-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    Path.join(dir, "snapshot")
  end

  defp source_file(bytes) do
    path = Path.join(System.tmp_dir!(), "archive-file-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "an unconfigured production archive refuses startup visibly" do
    assert {:error, :source_archive_not_configured} =
             BrusselsWtf.Archive.Unconfigured.start_link([])
  end

  test "derived processor bytes use a namespace distinct from raw evidence" do
    Application.put_env(:brussels_wtf, :archive, BrusselsWtf.Archive.Memory)
    bytes = "derived text"

    assert {:ok, %{object_key: "derived/sha256/" <> _} = archived} =
             BrusselsWtf.Archive.store(bytes, :derived)

    assert BrusselsWtf.Archive.get(archived.object_key) == {:ok, bytes}
  end
end
