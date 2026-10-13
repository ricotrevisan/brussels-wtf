# Credential-free OCR-only accounting contract. Never runs native suites or app/DB startup.
{:ok, [config]} = :file.consult(~c"/app/releases/0.1.0/sys.config")

Application.put_env(
  :brussels_wtf,
  :pdf_quality_thresholds,
  config |> Keyword.fetch!(:brussels_wtf) |> Keyword.fetch!(:pdf_quality_thresholds)
)

Code.compile_file("/code/lib/brussels_wtf/pdf/file_quality.ex")
Code.compile_file("/code/lib/brussels_wtf/pdf/file_processor.ex")
alias BrusselsWtf.PDF.FileProcessor
path = "/code/test/support/pdf_contract/forest-partial-scan.pdf"

hash = fn p ->
  File.stream!(p, [], 65_536)
  |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
  |> :crypto.hash_final()
  |> Base.encode16(case: :lower)
end

input_sha = hash.(path)
meta = %{sha256: input_sha, byte_size: File.stat!(path).size, media_type: "application/pdf"}
:ok = FileProcessor.validate_ocr_workspace("/scratch")
accounted = FileProcessor.ocr_metadata_accounted(cpu_seconds: 30, wall_time_ms: 30_000)
true = is_integer(accounted.cpu_ms) and accounted.cpu_ms > 0
started = System.monotonic_time(:millisecond)

{:ok, result} =
  FileProcessor.ocr_page(meta, path, 2, "/scratch",
    cpu_seconds: div(90_000 - accounted.cpu_ms, 1000),
    wall_time_ms: 120_000 - accounted.duration_ms
  )

true = result.original_pages == [2] and result.page_count == 1
true = result.quality_measurements["accepted"]
true = result.tool_versions == accounted.tool_versions
commands = Enum.sum(Enum.map(result.diagnostics, fn {_, diag} -> diag.cpu_ms end))
true = result.cpu_ms > commands
true = result.cpu_ms + accounted.cpu_ms <= 90_000
true = input_sha == hash.(path)
false = Enum.any?(Application.started_applications(), &(elem(&1, 0) == :brussels_wtf))

IO.puts(
  "OCR_ACCOUNTING_RECEIPT=" <>
    Jason.encode!(%{
      config_hash: accounted.config_hash,
      tool_versions: accounted.tool_versions,
      input_sha256: input_sha,
      original_pages: result.original_pages,
      metadata_cpu_ms: accounted.cpu_ms,
      page_cpu_ms: result.cpu_ms,
      command_cpu_ms: commands,
      aggregate_cpu_ms: result.cpu_ms + accounted.cpu_ms,
      page_wall_ms: System.monotonic_time(:millisecond) - started,
      metadata_wall_ms: accounted.duration_ms,
      text_sha256: hash.(result.text_path),
      pdf_sha256: hash.(result.searchable_pdf_path),
      text_byte_size: result.text_byte_size,
      pdf_byte_size: result.pdf_byte_size,
      quality_measurements: result.quality_measurements
    })
)

System.halt(0)
