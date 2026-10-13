defmodule BrusselsWtf.PDF.FileProcessorTest do
  use ExUnit.Case, async: true
  alias BrusselsWtf.PDF.{FileProcessor, Quality}
  @fixtures Path.expand("../../support/pdf_contract", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "file-pdf-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{workspace: dir}
  end

  test "native extraction is file backed, ordered and exactly Quality assessed", %{workspace: dir} do
    path = Path.join(@fixtures, "uccle-bilingual.pdf")
    assert {:ok, result} = FileProcessor.native(meta(path), path, dir)
    text = File.read!(result.text_path)
    pages = text |> String.split("\f") |> Enum.drop(-1)
    assert result.page_count == length(pages)
    assert result.page_count > 0
    assert result.quality_measurements == Quality.assess(pages)
    assert result.text_byte_size == byte_size(text)
    refute Map.has_key?(result, :text)
    refute Map.has_key?(result.output, "text")
    refute Map.has_key?(result.output, "page_texts")
    assert Bitwise.band(File.stat!(result.text_path).mode, 0o777) == 0o600
    assert String.starts_with?(result.text_path, dir <> "/")
    assert result.duration_ms >= 0
    assert result.tool_versions["pdftotext"] =~ "pdftotext version"
  end

  test "invalid input is rejected before tool execution or workspace writes", %{workspace: dir} do
    path = Path.join(@fixtures, "uccle-bilingual.pdf")
    expected = meta(path)

    assert {:error, {:unsupported_media, "text/html"}} =
             FileProcessor.native(%{expected | media_type: "text/html"}, path, dir)

    assert {:error, {:invalid_pdf, :checksum}} =
             FileProcessor.native(%{expected | sha256: String.duplicate("0", 64)}, path, dir)

    assert {:error, {:invalid_pdf, :byte_size}} =
             FileProcessor.native(%{expected | byte_size: expected.byte_size + 1}, path, dir)

    assert {:error, {:oversized_pdf, :byte_limit}} =
             FileProcessor.native(expected, path, dir, max_input_bytes: 1)

    signature = Path.join(dir, "bad-signature.pdf")
    File.write!(signature, "not a pdf")

    assert {:error, {:invalid_pdf, :signature}} =
             FileProcessor.native(meta(signature), signature, dir)

    link = Path.join(dir, "link.pdf")
    File.ln_s!(path, link)
    assert {:error, {:invalid_pdf, :not_regular_file}} = FileProcessor.native(expected, link, dir)
    File.rm!(signature)
    File.rm!(link)
    assert File.ls!(dir) == []
  end

  test "positive bounded page count is required before extracting", %{workspace: dir} do
    path = Path.join(@fixtures, "forest-partial-scan.pdf")

    assert {:error, {:oversized_pdf, :page_limit}} =
             FileProcessor.native(meta(path), path, dir, max_pages: 1)

    assert File.ls!(dir) == []
  end

  test "malformed and encrypted PDFs fail closed with safe classifications", %{workspace: dir} do
    for {file, expected} <- [
          {"malformed.pdf", {:invalid_pdf, :syntax}},
          {"encrypted.pdf", {:authentication_failure, :encrypted_pdf}}
        ] do
      path = Path.join(@fixtures, file)
      assert {:error, ^expected} = FileProcessor.native(meta(path), path, dir)
      assert File.ls!(dir) == []
    end
  end

  test "metadata pins distinct file-native identity, current Quality, tools and finite lower-only bounds" do
    metadata = FileProcessor.metadata()
    IO.puts("NATIVE_CONFIG_HASH=" <> metadata.config_hash)
    assert metadata.native_processor_name == "poppler-file-native-text"
    assert metadata.native_processor_version =~ "pdftotext version"
    assert metadata.tool_versions["python3"] =~ "Python 3."
    assert metadata.tool_versions["pdfinfo"] =~ "pdfinfo version"
    assert metadata.config_hash =~ ~r/^sha256:[0-9a-f]{64}$/
    assert metadata == FileProcessor.metadata()
    refute metadata.config_hash == FileProcessor.metadata(max_pages: 1).config_hash
    assert_raise ArgumentError, fn -> FileProcessor.metadata(max_pages: 501) end
    assert_raise ArgumentError, fn -> FileProcessor.metadata(wall_time_ms: :infinity) end
    assert_raise ArgumentError, fn -> FileProcessor.metadata(command: "/bin/sh") end
  end

  test "runtime cannot widen bounds or inject executables", %{workspace: dir} do
    path = Path.join(@fixtures, "uccle-bilingual.pdf")

    for opts <- [
          [max_pages: 501],
          [cpu_seconds: 0],
          [memory_bytes: -1],
          [max_input_bytes: 167_772_161],
          [wall_time_ms: :infinity],
          [command: "/bin/sh"]
        ] do
      assert {:error, {:invalid_pdf_limits, :options}} =
               FileProcessor.native(meta(path), path, dir, opts)
    end

    assert File.ls!(dir) == []
  end

  test "only private real workspaces are accepted without leaking paths", %{workspace: dir} do
    path = Path.join(@fixtures, "uccle-bilingual.pdf")
    File.chmod!(dir, 0o755)

    assert {:error, {:invalid_workspace, :private_directory_required}} =
             FileProcessor.native(meta(path), path, dir)

    File.chmod!(dir, 0o700)
    link = dir <> "-link"
    File.ln_s!(dir, link)
    on_exit(fn -> File.rm(link) end)

    assert {:error, {:invalid_workspace, :private_directory_required}} =
             FileProcessor.native(meta(path), path, link)
  end

  test "resource ceilings fail closed and remove only processor-owned output", %{workspace: dir} do
    path = Path.join(@fixtures, "uccle-bilingual.pdf")
    keep = Path.join(dir, "caller-owned")
    File.write!(keep, "keep")

    for {opts, reason} <- [
          {[cpu_seconds: 1], :cpu},
          {[max_output_bytes: 16], :output_bytes},
          {[max_diagnostic_bytes: 1], :diagnostics},
          {[memory_bytes: 1_048_576], :memory},
          {[wall_time_ms: 1], :wall_time},
          {[max_page_bytes: 16], :page_text_bytes}
        ] do
      assert {:error, {:processor_limit, ^reason}} =
               FileProcessor.native(meta(path), path, dir, opts)

      assert File.ls!(dir) == ["caller-owned"]
      assert File.read!(keep) == "keep"
    end
  end

  test "missing metadata or filesystem inputs are safe non-content errors", %{workspace: dir} do
    path = Path.join(@fixtures, "uccle-bilingual.pdf")
    assert {:error, {:invalid_pdf, :input_metadata}} = FileProcessor.native(%{}, path, dir)

    assert {:error, {:invalid_pdf, :input_file}} =
             FileProcessor.native(meta(path), Path.join(dir, "missing"), dir)

    assert {:error, {:invalid_pdf_limits, :options}} =
             FileProcessor.native(meta(path), path, dir, nil)

    assert File.ls!(dir) == []
  end

  defp meta(path) do
    bytes = File.read!(path)

    %{
      sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
      media_type: "application/pdf",
      byte_size: byte_size(bytes)
    }
  end
end
