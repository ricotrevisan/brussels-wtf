defmodule BrusselsWtf.ArchiveTest do
  use ExUnit.Case, async: false

  defmodule CorruptArchive do
    @behaviour BrusselsWtf.Archive
    def put(sha256, _bytes), do: {:ok, BrusselsWtf.Archive.object_key(sha256)}
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

  test "an unconfigured production archive refuses startup visibly" do
    assert {:error, :source_archive_not_configured} =
             BrusselsWtf.Archive.Unconfigured.start_link([])
  end
end
