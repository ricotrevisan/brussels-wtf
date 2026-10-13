ExUnit.start()

defmodule FileOCRContractTest do
  use ExUnit.Case, async: false
  alias BrusselsWtf.PDF.{FileProcessor, Quality}
  @fixtures "/code/test/support/pdf_contract"

  test "OCR provenance is separate, deterministic and lower-only" do
    meta = FileProcessor.ocr_metadata()
    IO.puts("OCR_CONFIG_HASH=" <> meta.config_hash)
    assert meta.ocr_processor_name == "ocrmypdf-file-page"
    assert meta.ocr_processor_version == "14.0.1"
    assert meta.tool_versions["qpdf"] == "qpdf version 11.3.0"
    assert meta.tool_versions["tesseract"] == "tesseract 5.3.0"
    assert meta.tool_versions["gs"] == "10.00.0"
    assert meta == FileProcessor.ocr_metadata()
    refute meta.config_hash == FileProcessor.metadata().config_hash
    refute meta.config_hash == FileProcessor.ocr_metadata(max_subset_bytes: 1024).config_hash

    for options <- [
          [max_subset_bytes: 26_214_401],
          [max_scratch_bytes: 536_870_913],
          [command: "/bin/sh"],
          [wall_time_ms: :infinity]
        ] do
      assert_raise ArgumentError, fn -> FileProcessor.ocr_metadata(options) end
    end
  end

  test "one rejected original page becomes one local Quality page and two retained files" do
    path = Path.join(@fixtures, "forest-partial-scan.pdf")
    assert {:ok, native} = FileProcessor.native(meta(path), path, "/scratch")
    assert native.quality_measurements["rejected_pages"] == [2]
    assert {:ok, result} = FileProcessor.ocr_page(meta(path), path, 2, "/scratch")
    assert result.page_count == 1
    assert result.original_pages == [2]
    text = File.read!(result.text_path)
    assert String.ends_with?(text, "\f")
    refute text =~ "FOREST"
    refute text =~ "VORST"
    assert result.quality_measurements == Quality.assess([String.trim_trailing(text, "\f")])
    assert result.quality_measurements["accepted"]
    assert result.quality_measurements["pages"] |> Enum.map(& &1["page"]) == [1]
    assert result.text_byte_size == byte_size(text)
    assert result.pdf_byte_size == File.stat!(result.searchable_pdf_path).size

    for file <- [result.text_path, result.searchable_pdf_path] do
      assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
    end

    assert Enum.sort(File.ls!(Path.dirname(result.text_path))) == ["ocr.pdf", "ocr.text"]
    refute Map.has_key?(result.output, "text")
    refute Map.has_key?(result.output, "page_texts")
    assert result.output["original_pages"] == [2]
    assert result.tool_versions == FileProcessor.ocr_metadata().tool_versions
    File.rm_rf!(Path.dirname(native.text_path))
    File.rm_rf!(Path.dirname(result.text_path))
  end

  test "source identity, page index and finite limits fail closed without removing caller files" do
    path = Path.join(@fixtures, "forest-partial-scan.pdf")
    keep = "/scratch/caller-owned"
    File.write!(keep, "keep")

    for page <- [0, -1, 1.5, false, "2", 3] do
      assert {:error, {:invalid_pdf, :original_page}} =
               FileProcessor.ocr_page(meta(path), path, page, "/scratch")
    end

    assert {:error, {:invalid_pdf, :checksum}} =
             FileProcessor.ocr_page(
               %{meta(path) | sha256: String.duplicate("0", 64)},
               path,
               2,
               "/scratch"
             )

    assert {:error, {:invalid_pdf, :byte_size}} =
             FileProcessor.ocr_page(%{meta(path) | byte_size: 1}, path, 2, "/scratch")

    assert {:error, {:oversized_pdf, :page_limit}} =
             FileProcessor.ocr_page(meta(path), path, 2, "/scratch", max_pages: 1)

    for {opts, expected} <- [
          {[max_subset_bytes: 16], {:processor_limit, :output_bytes}},
          {[memory_bytes: 1_048_576], {:processor_limit, :memory}},
          {[cpu_seconds: 1], {:processor_limit, :cpu}},
          {[wall_time_ms: 1], {:processor_limit, :wall_time}},
          {[max_output_bytes: 16], {:processor_limit, :output_bytes}},
          {[max_page_bytes: 16], {:processor_limit, :page_text_bytes}},
          {[max_input_bytes: 16], {:oversized_pdf, :byte_limit}},
          {[max_diagnostic_bytes: 1], {:processor_limit, :diagnostics}},
          {[max_pages: 501], {:invalid_pdf_limits, :options}},
          {[ocr_profile: :scanned_declaration], {:invalid_pdf_limits, :options}}
        ] do
      assert {:error, ^expected} = FileProcessor.ocr_page(meta(path), path, 2, "/scratch", opts)
    end

    for {file, expected} <- [
          {"encrypted.pdf", {:authentication_failure, :encrypted_pdf}},
          {"malformed.pdf", {:invalid_pdf, :syntax}},
          {"oversized-pages.pdf", {:oversized_pdf, :page_limit}}
        ] do
      path = Path.join(@fixtures, file)
      assert {:error, ^expected} = FileProcessor.ocr_page(meta(path), path, 1, "/scratch")
    end

    assert File.ls!("/scratch") == ["caller-owned"]
    assert File.read!(keep) == "keep"
    File.rm!(keep)
  end

  test "OCR refuses unbounded directories and reduced quota ceilings are not declarations" do
    path = Path.join(@fixtures, "forest-partial-scan.pdf")
    dir = "/tmp/nonquota"
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)

    assert {:error, {:invalid_workspace, :bounded_tmpfs_required}} =
             FileProcessor.ocr_page(meta(path), path, 2, dir)

    assert File.ls!(dir) == []

    assert {:error, {:invalid_workspace, :bounded_tmpfs_required}} =
             FileProcessor.ocr_page(meta(path), path, 2, "/scratch", max_scratch_bytes: 1024)

    File.rmdir!(dir)
  end

  test "kernel quota exhaustion is classified and cleans only processor scratch" do
    path = Path.join(@fixtures, "forest-partial-scan.pdf")
    fill = "/tiny/caller-fill"
    File.write!(fill, :binary.copy(<<0>>, 4_100_000))

    assert {:error, {:processor_limit, :scratch_bytes}} =
             FileProcessor.ocr_page(meta(path), path, 2, "/tiny", max_scratch_bytes: 4_194_304)

    assert File.ls!("/tiny") == ["caller-fill"]
    assert File.stat!(fill).size == 4_100_000
    File.rm!(fill)
  end

  test "blank OCR is not exempted and rejected quality retains both caller-owned artifacts" do
    path = "/scratch/blank.pdf"

    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << >> >>",
      "<< /Length 0 >>\nstream\n\nendstream"
    ]

    {pdf, offsets} =
      Enum.with_index(objects, 1)
      |> Enum.reduce({"%PDF-1.4\n", []}, fn {obj, index}, {pdf, offsets} ->
        {pdf <> "#{index} 0 obj\n#{obj}\nendobj\n", offsets ++ [byte_size(pdf)]}
      end)

    xref =
      "xref\n0 5\n0000000000 65535 f \n" <>
        Enum.map_join(offsets, fn offset ->
          String.pad_leading(to_string(offset), 10, "0") <> " 00000 n \n"
        end)

    File.write!(
      path,
      pdf <> xref <> "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n#{byte_size(pdf)}\n%%EOF\n"
    )

    assert {:ok, result} = FileProcessor.ocr_page(meta(path), path, 1, "/scratch")
    refute result.quality_measurements["accepted"]
    assert result.quality_measurements == Quality.assess([""])
    assert result.original_pages == [1]
    assert File.read!(result.text_path) == "\f"
    assert File.regular?(result.searchable_pdf_path)
    assert Enum.sort(File.ls!(Path.dirname(result.text_path))) == ["ocr.pdf", "ocr.text"]
    File.rm_rf!(Path.dirname(result.text_path))
    File.rm!(path)
  end

  test "a completely full scratch quota still returns a safe resource error" do
    path = Path.join(@fixtures, "forest-partial-scan.pdf")
    fill = "/tiny/full-quota"
    File.write!(fill, :binary.copy(<<0>>, 4_194_304))

    assert {:error, {:processor_limit, :scratch_bytes}} =
             FileProcessor.ocr_page(meta(path), path, 2, "/tiny", max_scratch_bytes: 4_194_304)

    assert File.ls!("/tiny") == ["full-quota"]
    File.rm!(fill)
  end

  test "scratch inode exhaustion is a resource error even when diagnostic files cannot be created" do
    path = Path.join(@fixtures, "forest-partial-scan.pdf")

    assert {:error, {:processor_limit, :scratch_bytes}} =
             FileProcessor.ocr_page(meta(path), path, 2, "/inodes", max_scratch_bytes: 4_194_304)

    assert File.ls!("/inodes") == []
  end

  defp meta(path) do
    bytes = File.read!(path)

    %{
      media_type: "application/pdf",
      byte_size: byte_size(bytes),
      sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    }
  end
end
