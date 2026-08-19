defmodule BrusselsWtf.PDF.PopplerOcr do
  @moduledoc "Bounded Poppler-first PDF extraction with page-selective bilingual OCR."
  @behaviour BrusselsWtf.PDF.Processor

  alias BrusselsWtf.PDF.Quality

  @native_flags ["-layout"]
  @ocr_flags [
    "--output-type",
    "pdf",
    "--rotate-pages",
    "--redo-ocr",
    "--jobs",
    "1",
    "--verbose",
    "1"
  ]

  @impl true
  def native(meta, bytes) do
    started = System.monotonic_time()

    with :ok <- validate_input(meta, bytes),
         {:ok, result} <- workspace(fn dir -> native_in(dir, bytes) end) do
      quality = Quality.assess(result.page_texts)

      {:ok,
       %{
         output: %{
           "text" => result.text,
           "page_texts" => result.page_texts,
           "page_count" => result.page_count,
           "language_signals" => Quality.language_signals(result.page_texts),
           "quality_measurements" => quality
         },
         text: result.text,
         page_count: result.page_count,
         quality_measurements: quality,
         diagnostics: %{
           "pdfinfo_status" => 0,
           "pdftotext_status" => 0,
           "encrypted" => result.encrypted
         },
         tool_versions: metadata().tool_versions,
         duration_ms: elapsed_ms(started)
       }}
    end
  end

  @impl true
  def ocr(meta, bytes, pages) when is_list(pages) and pages != [] do
    started = System.monotonic_time()

    with :ok <- validate_input(meta, bytes),
         {:ok, result} <- workspace(fn dir -> ocr_in(dir, bytes, pages) end) do
      quality = Quality.assess(result.page_texts)

      {:ok,
       %{
         output: %{
           "text" => result.text,
           "page_texts" => result.page_texts,
           "page_count" => result.page_count,
           "language_signals" => Quality.language_signals(result.page_texts),
           "quality_measurements" => quality
         },
         text: result.text,
         searchable_pdf: result.pdf,
         page_count: result.page_count,
         quality_measurements: quality,
         diagnostics: %{
           "ocrmypdf_status" => 0,
           "pdftotext_status" => 0,
           "pages" => pages,
           "languages" => limits().ocr_languages
         },
         tool_versions: metadata().tool_versions,
         duration_ms: elapsed_ms(started)
       }}
    end
  end

  def ocr(_meta, _bytes, _pages), do: {:error, {:invalid_ocr_pages, :empty}}

  @impl true
  def metadata do
    versions = %{
      "pdfinfo" => version("pdfinfo", ["-v"]),
      "pdftotext" => version("pdftotext", ["-v"]),
      "ocrmypdf" => version("ocrmypdf", ["--version"]),
      "tesseract" => version("tesseract", ["--version"]),
      "tesseract_languages" => tesseract_languages()
    }

    contract = %{
      "schema" => "pdf-extraction-v1",
      "quality" => Quality.thresholds(),
      "limits" => limits(),
      "native_flags" => @native_flags,
      "ocr_flags" => @ocr_flags,
      "versions" => versions
    }

    %{
      native_processor_name: "poppler-native-text",
      native_processor_version: versions["pdftotext"],
      ocr_processor_name: "ocrmypdf-tesseract",
      ocr_processor_version: versions["ocrmypdf"],
      config_hash:
        "sha256:" <> BrusselsWtf.Digest.sha256(:erlang.term_to_binary(contract, [:deterministic])),
      tool_versions: versions
    }
  end

  defp native_in(dir, bytes) do
    input = Path.join(dir, "input.pdf")
    File.write!(input, bytes, [:binary])

    with {:ok, info} <- command("pdfinfo", [input], native_wall_ms()),
         {:ok, page_count} <- page_count(info),
         :ok <- validate_page_count(page_count),
         {:ok, text} <- command("pdftotext", @native_flags ++ [input, "-"], native_wall_ms()) do
      {:ok,
       %{
         text: text,
         page_texts: page_texts(text, page_count),
         page_count: page_count,
         encrypted: Regex.match?(~r/^Encrypted:\s+yes/im, info)
       }}
    end
  end

  defp ocr_in(dir, bytes, pages) do
    input = Path.join(dir, "input.pdf")
    output = Path.join(dir, "ocr.pdf")
    File.write!(input, bytes, [:binary])

    page_arg = pages |> Enum.sort() |> Enum.join(",")

    args =
      ["--pages", page_arg, "--language", limits().ocr_languages] ++
        @ocr_flags ++ [input, output]

    with {:ok, _safe_output} <- ocr_command(args),
         {:ok, info} <- command("pdfinfo", [output], native_wall_ms()),
         {:ok, page_count} <- page_count(info),
         {:ok, text} <- command("pdftotext", @native_flags ++ [output, "-"], native_wall_ms()),
         {:ok, pdf} <- File.read(output) do
      {:ok,
       %{pdf: pdf, text: text, page_texts: page_texts(text, page_count), page_count: page_count}}
    end
  end

  defp validate_input(%{media_type: media_type}, bytes) do
    cond do
      media_type != "application/pdf" -> {:error, {:unsupported_media, media_type}}
      byte_size(bytes) > limits().max_input_bytes -> {:error, {:oversized_pdf, :byte_limit}}
      not String.starts_with?(bytes, "%PDF-") -> {:error, {:invalid_pdf, :signature}}
      true -> :ok
    end
  end

  defp validate_page_count(count) do
    cond do
      count <= 0 -> {:error, {:invalid_pdf, :page_count}}
      count > limits().max_pages -> {:error, {:oversized_pdf, :page_limit}}
      true -> :ok
    end
  end

  defp page_count(info) do
    case Regex.run(~r/^Pages:\s+(\d+)$/m, info) do
      [_, count] -> {:ok, String.to_integer(count)}
      _ -> {:error, {:invalid_pdf, :missing_page_count}}
    end
  end

  defp page_texts(text, expected) do
    pages =
      text
      |> String.split("\f", trim: false)
      |> drop_trailing_empty()

    (pages ++ List.duplicate("", max(expected - length(pages), 0)))
    |> Enum.take(expected)
  end

  defp drop_trailing_empty([]), do: []

  defp drop_trailing_empty(pages) do
    if String.trim(List.last(pages)) == "", do: Enum.drop(pages, -1), else: pages
  end

  defp ocr_command(args) do
    limit = limits()
    seconds = max(div(limit.ocr_wall_time_ms + 999, 1_000), 1)

    full_args =
      [
        "--signal=TERM",
        "--kill-after=5s",
        "#{seconds}s",
        "prlimit",
        "--cpu=#{limit.ocr_cpu_seconds}",
        "--as=#{limit.ocr_memory_bytes}",
        "--",
        "ocrmypdf"
      ] ++ args

    case raw_command("timeout", full_args) do
      {:ok, output, 0} ->
        {:ok, output}

      {:ok, _output, 124} ->
        {:error, {:ocr_limit, :wall_time}}

      {:ok, _output, 137} ->
        {:error, {:ocr_limit, :memory_or_kill}}

      {:ok, _output, 152} ->
        {:error, {:ocr_limit, :cpu}}

      {:ok, _output, 2} ->
        {:error, {:invalid_content, {:ocrmypdf_exit, 2}}}

      {:ok, _output, 3} ->
        {:error, {:processor_unavailable, "ocrmypdf-dependency"}}

      {:ok, _output, 8} ->
        {:error, {:authentication_failure, :encrypted_pdf}}

      {:ok, output, 7} ->
        if signaled_child_failure?(output) do
          {:error, {:ocr_limit, :cpu_memory_or_kill}}
        else
          {:error, {:ocr_failed, {:child_process, 7}}}
        end

      {:ok, output, status} ->
        if memory_limit_failure?(output) do
          {:error, {:ocr_limit, :memory}}
        else
          {:error, {:ocr_failed, status}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp signaled_child_failure?(output) do
    String.contains?(output, ["Signals.SIGKILL", "Signals.SIGXCPU"])
  end

  defp memory_limit_failure?(output) do
    normalized = String.downcase(output)

    Enum.any?(
      ["failed to map segment", "cannot allocate memory", "memoryerror"],
      &String.contains?(normalized, &1)
    )
  end

  defp command(executable, args, wall_ms) do
    seconds = max(div(wall_ms + 999, 1_000), 1)

    case raw_command("timeout", ["--signal=KILL", "#{seconds}s", executable | args]) do
      {:ok, output, 0} -> {:ok, output}
      {:ok, _output, 124} -> {:error, {:processor_limit, :wall_time}}
      {:ok, output, status} -> {:error, classify_exit(executable, status, output)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp raw_command(executable, args) do
    try do
      {output, status} = System.cmd(executable, args, stderr_to_stdout: true)
      {:ok, output, status}
    rescue
      _ -> {:error, {:processor_unavailable, executable}}
    end
  end

  defp classify_exit(executable, status, output)
       when executable in ["pdfinfo", "pdftotext"] do
    if String.contains?(String.downcase(output), "password") do
      {:authentication_failure, :encrypted_pdf}
    else
      classify_pdf_exit(executable, status, output)
    end
  end

  defp classify_exit(executable, status, _output),
    do: {:processor_failed, {executable, status}}

  defp classify_pdf_exit("pdfinfo", status, output) do
    if String.contains?(String.downcase(output), "syntax error") do
      {:invalid_pdf, :syntax}
    else
      {:processor_failed, {"pdfinfo", status}}
    end
  end

  defp classify_pdf_exit("pdftotext", status, _output),
    do: {:processor_failed, {"pdftotext", status}}

  defp tesseract_languages do
    case raw_command("tesseract", ["--list-langs"]) do
      {:ok, output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&(&1 in ["fra", "nld", "osd"]))
        |> Enum.sort()
        |> Enum.join(",")

      _ ->
        "unavailable"
    end
  end

  defp version(executable, args) do
    case raw_command(executable, args) do
      {:ok, output, 0} ->
        output |> String.split("\n", trim: true) |> List.first() |> sanitize_version()

      _ ->
        "unavailable"
    end
  end

  defp sanitize_version(nil), do: "unknown"
  defp sanitize_version(value), do: value |> String.trim() |> String.slice(0, 120)

  defp workspace(fun) do
    dir = Path.join(System.tmp_dir!(), "brussels-wtf-pdf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  defp elapsed_ms(started),
    do: System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

  defp limits, do: Application.fetch_env!(:brussels_wtf, :pdf_limits)
  defp native_wall_ms, do: min(limits().ocr_wall_time_ms, 30_000)
end
