defmodule BrusselsWtf.PDF.Stub do
  @moduledoc false
  @behaviour BrusselsWtf.PDF.Processor

  alias BrusselsWtf.PDF.Quality

  @impl true
  def native(meta, bytes) do
    started = System.monotonic_time()

    with {:ok, extracted} <- BrusselsWtf.Processors.extract(meta, bytes) do
      text = Map.get(extracted, "text", "")
      page_texts = Map.get(extracted, "page_texts", [text])
      quality = Quality.assess(page_texts)

      duration =
        System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

      {:ok,
       %{
         output:
           extracted
           |> Map.put("page_count", length(page_texts))
           |> Map.put("language_signals", Quality.language_signals(page_texts)),
         text: Enum.join(page_texts, ""),
         page_count: length(page_texts),
         quality_measurements: quality,
         diagnostics: %{"pdfinfo_status" => 0, "pdftotext_status" => 0},
         tool_versions: metadata().tool_versions,
         duration_ms: duration
       }}
    end
  end

  @impl true
  def ocr(%{sha256: sha256}, _bytes, pages) do
    started = System.monotonic_time()

    with {:ok, output} <- BrusselsWtf.Processors.Stub.pdf_fixture(sha256, :ocr),
         {:ok, output} <- unwrap_output(output) do
      page_texts = Map.fetch!(output, "page_texts")
      quality = Quality.assess(page_texts)

      duration =
        System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

      {:ok,
       %{
         output:
           output
           |> Map.put("text", Enum.join(page_texts, "\f"))
           |> Map.put("page_count", length(page_texts))
           |> Map.put("quality_measurements", quality)
           |> Map.put("language_signals", Quality.language_signals(page_texts)),
         text: Enum.join(page_texts, "\f"),
         searchable_pdf: Map.fetch!(output, "searchable_pdf"),
         page_count: length(page_texts),
         quality_measurements: quality,
         diagnostics: %{
           "ocrmypdf_status" => 0,
           "pages" => pages,
           "languages" => "fra+nld"
         },
         tool_versions: metadata().tool_versions,
         duration_ms: duration
       }}
    end
  end

  defp unwrap_output({:error, reason}), do: {:error, reason}
  defp unwrap_output(output) when is_map(output), do: {:ok, output}

  @impl true
  def metadata do
    %{
      native_processor_name: "poppler-native-text",
      native_processor_version: "fixture-poppler-24.02",
      ocr_processor_name: "ocrmypdf-tesseract",
      ocr_processor_version: "fixture-ocrmypdf-16",
      config_hash: "sha256:fixture-pdf-quality-v1",
      tool_versions: %{
        "pdfinfo" => "fixture-poppler-24.02",
        "pdftotext" => "fixture-poppler-24.02",
        "ocrmypdf" => "fixture-ocrmypdf-16",
        "tesseract" => "fixture-tesseract-5",
        "tesseract_languages" => "fra,nld,osd"
      }
    }
  end
end
