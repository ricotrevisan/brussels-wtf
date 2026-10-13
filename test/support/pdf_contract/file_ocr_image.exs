# Credential-free exact-image cover tracer. Originals are mounted read-only.
{:ok, [config]} = :file.consult(~c"/app/releases/0.1.0/sys.config")

Application.put_env(
  :brussels_wtf,
  :pdf_quality_thresholds,
  config |> Keyword.fetch!(:brussels_wtf) |> Keyword.fetch!(:pdf_quality_thresholds)
)

Code.compile_file("/code/lib/brussels_wtf/pdf/file_quality.ex")
Code.compile_file("/code/lib/brussels_wtf/pdf/file_processor.ex")
alias BrusselsWtf.PDF.FileProcessor

hash_file = fn path ->
  File.stream!(path, [], 65_536)
  |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
  |> :crypto.hash_final()
  |> Base.encode16(case: :lower)
end

expected = "fe44ef01655dad208af23c2284ad1ced161e3f9fe6040f4963490100a7b0579b"
meta = %{sha256: expected, byte_size: 44_148_957, media_type: "application/pdf"}
metadata = FileProcessor.ocr_metadata()

result =
  case FileProcessor.ocr_page(meta, "/input/source.pdf", 1, "/scratch") do
    {:ok, result} ->
      true = result.page_count == 1 and result.original_pages == [1]
      true = result.tool_versions == metadata.tool_versions
      true = FileProcessor.ocr_metadata() == metadata
      File.cp!(result.text_path, "/out/ocr.text.private")
      File.cp!(result.searchable_pdf_path, "/out/ocr.pdf.private")

      %{
        "status" => "ok",
        "page_count" => result.page_count,
        "original_pages" => result.original_pages,
        "quality_measurements" => result.quality_measurements,
        "text_sha256" => hash_file.(result.text_path),
        "pdf_sha256" => hash_file.(result.searchable_pdf_path),
        "text_byte_size" => result.text_byte_size,
        "pdf_byte_size" => result.pdf_byte_size,
        "duration_ms" => result.duration_ms,
        "diagnostics" => result.diagnostics,
        "tool_versions" => result.tool_versions,
        "text_mode" => Bitwise.band(File.stat!(result.text_path).mode, 0o777),
        "pdf_mode" => Bitwise.band(File.stat!(result.searchable_pdf_path).mode, 0o777),
        "output_has_text" =>
          Map.has_key?(result.output, "text") or Map.has_key?(result.output, "page_texts"),
        "retained_files" => Enum.sort(File.ls!(Path.dirname(result.text_path)))
      }

    {:error, {kind, reason}} ->
      %{"status" => "error", "classification" => [to_string(kind), inspect(reason)]}
  end

false = Enum.any?(Application.started_applications(), &(elem(&1, 0) == :brussels_wtf))

result =
  result
  |> Map.put("metadata", metadata)
  |> Map.put("input_sha256_after", hash_file.("/input/source.pdf"))
  |> Map.put("quality_beam_sha256", hash_file.(to_string(:code.which(BrusselsWtf.PDF.Quality))))
  |> Map.put(
    "started_applications",
    Enum.map(Application.started_applications(), &to_string(elem(&1, 0)))
  )

File.write!("/out/module-receipt.json", Jason.encode!(result))
File.chmod!("/out/module-receipt.json", 0o600)
IO.puts("FILE_OCR_PAGE_CONTRACT_COMPLETE")
if result["status"] != "ok", do: System.halt(1)
