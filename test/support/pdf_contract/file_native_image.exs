# Credential-free direct-module contract. Never boots the application/release.
{:ok, [config]} = :file.consult(~c"/app/releases/0.1.0/sys.config")
thresholds = config |> Keyword.fetch!(:brussels_wtf) |> Keyword.fetch!(:pdf_quality_thresholds)
Application.put_env(:brussels_wtf, :pdf_quality_thresholds, thresholds)
Code.compile_file("/code/lib/brussels_wtf/pdf/file_quality.ex")
Code.compile_file("/code/lib/brussels_wtf/pdf/file_processor.ex")
[input, sha256, bytes, workspace, receipt] = System.argv()
meta = %{sha256: sha256, media_type: "application/pdf", byte_size: String.to_integer(bytes)}

hash_file = fn path ->
  context =
    File.stream!(path, [], 65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))

  Base.encode16(:crypto.hash_final(context), case: :lower)
end

result =
  case BrusselsWtf.PDF.FileProcessor.native(meta, input, workspace) do
    {:ok, result} ->
      %{
        "status" => "ok",
        "page_count" => result.page_count,
        "quality_measurements" => result.quality_measurements,
        "text_sha256" => hash_file.(result.text_path),
        "text_byte_size" => result.text_byte_size,
        "text_mode" => Bitwise.band(File.stat!(result.text_path).mode, 0o777),
        "duration_ms" => result.duration_ms,
        "diagnostics" => result.diagnostics,
        "tool_versions" => result.tool_versions,
        "metadata" => BrusselsWtf.PDF.FileProcessor.metadata(),
        "output_has_text" =>
          Map.has_key?(result.output, "text") or Map.has_key?(result.output, "page_texts")
      }

    {:error, {kind, reason}} ->
      %{"status" => "error", "classification" => [to_string(kind), inspect(reason)]}
  end

false = Enum.any?(Application.started_applications(), &(elem(&1, 0) == :brussels_wtf))

result =
  result
  |> Map.put("input_sha256_after", hash_file.(input))
  |> Map.put(
    "started_applications",
    Enum.map(Application.started_applications(), &to_string(elem(&1, 0)))
  )
  |> Map.put("quality_beam_sha256", hash_file.(to_string(:code.which(BrusselsWtf.PDF.Quality))))

File.write!(receipt, Jason.encode!(result))
File.chmod!(receipt, 0o600)
IO.puts("FILE_NATIVE_CONTRACT_COMPLETE")
