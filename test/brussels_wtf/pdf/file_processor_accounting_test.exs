defmodule BrusselsWtf.PDF.FileProcessorAccountingTest do
  use ExUnit.Case, async: true
  alias BrusselsWtf.PDF.FileProcessor

  test "native aggregate includes all invocation probes, not only extraction commands" do
    path = Path.expand("../../support/pdf_contract/uccle-bilingual.pdf", __DIR__)
    dir = Path.join(System.tmp_dir!(), "ocr-accounting-#{Ecto.UUID.generate()}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)

    try do
      meta = %{
        sha256: BrusselsWtf.Digest.sha256(File.read!(path)),
        media_type: "application/pdf",
        byte_size: File.stat!(path).size
      }

      assert {:ok, result} = FileProcessor.native(meta, path, dir)
      assert is_integer(result.cpu_ms)
      commands = Enum.sum(Enum.map(result.diagnostics, fn {_, diag} -> diag.cpu_ms end))
      assert result.cpu_ms >= commands
      assert result.cpu_ms > commands
    after
      File.rm_rf!(dir)
    end
  end

  test "accounted metadata lowers probe bounds without changing pinned default provenance" do
    metadata = FileProcessor.ocr_metadata()
    accounted = FileProcessor.ocr_metadata_accounted(cpu_seconds: 30, wall_time_ms: 30_000)
    assert Map.drop(accounted, [:cpu_ms, :duration_ms]) == metadata
    assert is_integer(accounted.cpu_ms) and accounted.cpu_ms > 0
    assert accounted.duration_ms > 0
  end

  test "admission rejects a private directory which is not a dedicated quota mount" do
    dir = Path.join(System.tmp_dir!(), "quota-admission-#{Ecto.UUID.generate()}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)

    try do
      assert {:error, {:invalid_workspace, :bounded_tmpfs_required}} =
               FileProcessor.validate_ocr_workspace(dir)
    after
      File.rmdir!(dir)
    end
  end
end
