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
