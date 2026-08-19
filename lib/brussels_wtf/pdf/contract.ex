defmodule BrusselsWtf.PDF.Contract do
  @moduledoc false

  def print_from_env do
    path = System.fetch_env!("PDF_CONTRACT_PATH")
    mode = System.get_env("PDF_CONTRACT_MODE", "native")
    bytes = File.read!(path)
    meta = %{sha256: BrusselsWtf.Digest.sha256(bytes), media_type: "application/pdf"}

    result =
      case mode do
        "native" ->
          BrusselsWtf.PDF.Processor.native(meta, bytes)

        "ocr" ->
          BrusselsWtf.PDF.Processor.ocr(
            meta,
            bytes,
            parse_pages(System.fetch_env!("PDF_CONTRACT_PAGES"))
          )
      end

    safe =
      case result do
        {:ok, value} ->
          %{
            status: "ok",
            page_count: value.page_count,
            quality_measurements: value.quality_measurements,
            tool_versions: value.tool_versions,
            text_sha256: BrusselsWtf.Digest.sha256(value.text),
            pdf_sha256:
              if(Map.has_key?(value, :searchable_pdf),
                do: BrusselsWtf.Digest.sha256(value.searchable_pdf),
                else: nil
              )
          }

        {:error, reason} ->
          %{status: "error", classification: safe_reason(reason)}
      end

    IO.puts("PDF_CONTRACT_JSON=" <> Jason.encode!(safe))
  end

  defp parse_pages(value),
    do: value |> String.split(",", trim: true) |> Enum.map(&String.to_integer/1)

  defp safe_reason({kind, detail}) when is_atom(kind),
    do: [Atom.to_string(kind), safe_detail(detail)]

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "processing_failure"
  defp safe_detail(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_detail(value) when is_integer(value), do: value
  defp safe_detail({name, value}) when is_binary(name) and is_integer(value), do: [name, value]
  defp safe_detail(_value), do: "redacted"
end
