defmodule BrusselsWtf.PDF.FileProcessor do
  @moduledoc """
  File-backed native extraction and bounded one-page subset OCR. The caller
  owns a private workspace and cleanup; successful PDF/text files are 0600.
  No source/text binaries are returned. Pinned file-backed limits do not change
  the ordinary binary processor. Options can only reduce finite limits, never
  select tools, OCR profiles or shell flags.
  """
  alias BrusselsWtf.PDF.Quality

  @defaults %{
    max_input_bytes: 167_772_160,
    max_pages: 500,
    wall_time_ms: 120_000,
    cpu_seconds: 90,
    memory_bytes: 1_073_741_824,
    max_output_bytes: 67_108_864,
    max_diagnostic_bytes: 1_048_576,
    max_page_bytes: 262_144
  }
  @script Path.expand("../../../priv/pdf/bounded_command.py", __DIR__)
  @implementation_sha :crypto.hash(:sha256, File.read!(__ENV__.file))
  @quality_sha :crypto.hash(:sha256, File.read!(Path.join(__DIR__, "file_quality.ex")))

  def native(meta, input_path, workspace, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    with {:ok, limits} <- limits(opts),
         :ok <- validate_workspace(workspace),
         :ok <-
           validate_input(
             meta,
             input_path,
             Map.put(limits, :deadline_ms, started + limits.wall_time_ms)
           ) do
      dir = Path.join(Path.expand(workspace), "native-" <> random_id())
      File.mkdir!(dir)
      File.chmod!(dir, 0o700)

      result =
        try do
          extract(input_path, dir, limits, started)
        rescue
          _ -> {:error, {:processor_failed, :file_native}}
        catch
          {:processor_limit, _} = reason -> {:error, reason}
          _ -> {:error, {:processor_failed, :file_native}}
        end

      case result do
        {:ok, result} ->
          for file <- File.ls!(dir), file != "native.text", do: File.rm(Path.join(dir, file))
          {:ok, result}

        error ->
          File.rm_rf(dir)
          error
      end
    end
  rescue
    _ -> {:error, {:processor_failed, :file_native}}
  end

  def metadata(opts \\ []) do
    limits =
      case limits(opts) do
        {:ok, limits} -> limits
        _ -> raise ArgumentError, "invalid file-native PDF limits"
      end

    dir = Path.join(System.tmp_dir!(), "pdf-file-metadata-" <> random_id())
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)

    try do
      versions = versions(dir)

      contract = %{
        schema: "pdf-file-native-v2",
        cpu_accounting:
          "owned_tree_wait_delta;invocation_ledger;floor_remaining;10ms_poll;50ms_reserve",
        implementation_sha256: @implementation_sha,
        quality_sha256: @quality_sha,
        wrapper_sha256: :crypto.hash(:sha256, File.read!(script())),
        quality: Quality.thresholds(),
        limits: limits,
        native_flags: ["-layout"],
        tool_versions: versions
      }

      %{
        native_processor_name: "poppler-file-native-text",
        native_processor_version: versions["pdftotext"],
        tool_versions: versions,
        config_hash:
          "sha256:" <>
            Base.encode16(
              :crypto.hash(
                :sha256,
                :erlang.term_to_binary(contract, [:deterministic])
              ),
              case: :lower
            )
      }
    after
      File.rm_rf(dir)
    end
  end

  @ocr_defaults Map.merge(@defaults, %{
                  max_subset_bytes: 26_214_400,
                  max_scratch_bytes: 536_870_912
                })
  @ocr_flags [
    "--output-type",
    "pdf",
    "--rotate-pages",
    "--redo-ocr",
    "--jobs",
    "1",
    "--verbose",
    "1",
    "--language",
    "fra+nld"
  ]

  def ocr_metadata(opts \\ []), do: ocr_metadata_impl(opts, [], false)

  @doc "Default provenance with lower-only accounted probe CPU/wall limits."
  def ocr_metadata_accounted(probe_opts), do: ocr_metadata_impl([], probe_opts, true)

  defp ocr_metadata_impl(opts, probe_opts, accounted?) do
    limits =
      case ocr_limits(opts) do
        {:ok, limits} -> limits
        _ -> raise ArgumentError, "invalid file-page OCR limits"
      end

    dir = Path.join(System.tmp_dir!(), "pdf-ocr-metadata-" <> random_id())
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)

    try do
      {:ok, probe_limits} = ocr_limits(probe_opts)
      started = System.monotonic_time(:millisecond)
      versions = ocr_versions(dir, probe_limits, started)

      contract = %{
        schema: "pdf-file-ocr-page-v2",
        cpu_accounting:
          "owned_tree_wait_delta;invocation_ledger;floor_remaining;10ms_poll;50ms_reserve",
        quality_sha256: @quality_sha,
        limits: limits,
        quality: Quality.thresholds(),
        subset_flags: ["--pages", "input", "original_page", "--", "subset.pdf"],
        ocr_flags: @ocr_flags,
        native_flags: ["-layout"],
        tool_versions: versions,
        page_map: "local_quality_page_1;original_pages=[original_page]",
        output_schema: "file_paths_sizes;page_count=1;summary_without_text;safe_diagnostics",
        workspace: "dedicated_private_tmpfs_mount_bounded_during_execution",
        implementation_sha256: @implementation_sha,
        wrapper_sha256: :crypto.hash(:sha256, File.read!(script()))
      }

      metadata = %{
        ocr_processor_name: "ocrmypdf-file-page",
        ocr_processor_version: versions["ocrmypdf"],
        tool_versions: versions,
        config_hash:
          "sha256:" <>
            Base.encode16(
              :crypto.hash(:sha256, :erlang.term_to_binary(contract, [:deterministic])),
              case: :lower
            )
      }

      if accounted?,
        do:
          Map.merge(metadata, %{
            cpu_ms: invocation_cpu_ms(dir),
            duration_ms: System.monotonic_time(:millisecond) - started
          }),
        else: metadata
    after
      File.rm_rf(dir)
    end
  end

  defp ocr_limits(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(opts, fn {k, v} ->
           is_map_key(@ocr_defaults, k) and is_integer(v) and v > 0 and
             v <= Map.fetch!(@ocr_defaults, k)
         end),
       do: {:ok, Map.merge(@ocr_defaults, Map.new(opts))},
       else: {:error, {:invalid_pdf_limits, :options}}
  end

  defp ocr_versions(dir, limits, started) do
    versions(dir, limits, started)
    |> Map.merge(
      Map.new(
        [
          {"qpdf", "--version", ~r/qpdf version [0-9.]+/},
          {"ocrmypdf", "--version", ~r/\b[0-9]+\.[0-9]+\.[0-9]+\b/},
          {"gs", "--version", ~r/\b[0-9]+\.[0-9]+\.[0-9]+\b/},
          {"tesseract", "--version", ~r/tesseract [0-9.]+/}
        ],
        fn {tool, flag, regex} ->
          value =
            case command(tool, [flag], dir, limits, started) do
              {:ok, out, diag} ->
                case Regex.run(regex, out <> File.read!(diag.stderr_path)) do
                  [value] -> value
                  _ -> "unavailable"
                end

              {:error, {:processor_limit, _} = reason} ->
                throw(reason)

              _ ->
                "unavailable"
            end

          {tool, value}
        end
      )
    )
  end

  @doc """
  OCR exactly one original page. Quality page numbering remains local (1);
  `original_pages` is the explicit original-source map. The caller authorizes
  rejected pages, archives both outputs even on quality rejection, and owns
  cleanup. Requires a dedicated quota-backed 0700 tmpfs workspace; the caller
  must additionally isolate the worker at one CPU / 1 GiB, concurrency one.
  FileProcessor enforces cumulative owned-process-tree CPU per page invocation;
  the caller separately bounds the aggregate across multiple page invocations.
  """
  def ocr_page(meta, input_path, original_page, workspace, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    with {:ok, limits} <- ocr_limits(opts),
         true <-
           (is_integer(original_page) and original_page > 0) ||
             {:error, {:invalid_pdf, :original_page}},
         :ok <- validate_workspace(workspace),
         :ok <- validate_quota(workspace, limits),
         :ok <-
           validate_input(
             meta,
             input_path,
             Map.put(limits, :deadline_ms, started + limits.wall_time_ms)
           ) do
      dir = Path.join(Path.expand(workspace), "ocr-page-" <> random_id())
      File.mkdir!(dir)
      File.chmod!(dir, 0o700)
      scratch = Path.join(dir, "scratch")
      File.mkdir!(scratch)
      File.chmod!(scratch, 0o700)
      limits = Map.put(limits, :scratch_dir, scratch)

      result =
        try do
          extract_ocr(Path.expand(input_path), original_page, dir, limits, started)
        rescue
          _ -> {:error, {:processor_failed, :file_ocr_page}}
        catch
          {:processor_limit, _} = reason -> {:error, reason}
          _ -> {:error, {:processor_failed, :file_ocr_page}}
        end

      case result do
        {:ok, result} ->
          for file <- File.ls!(dir),
              file not in ["ocr.text", "ocr.pdf"],
              do: File.rm_rf(Path.join(dir, file))

          {:ok, result}

        error ->
          File.rm_rf(dir)
          error
      end
    end
  rescue
    _ -> {:error, {:processor_failed, :file_ocr_page}}
  end

  @doc "Validate the caller-owned dedicated quota mount before any archive writes."
  def validate_ocr_workspace(workspace) do
    with :ok <- validate_workspace(workspace), do: validate_quota(workspace, @ocr_defaults)
  end

  defp invocation_cpu_ms(dir) do
    case Integer.parse(File.read!(Path.join(dir, "cpu.budget"))) do
      {used, ""} when used >= 0 -> used
      _ -> raise ArgumentError, "invalid private invocation accounting"
    end
  end

  defp validate_quota(workspace, limits) do
    case System.cmd(
           "/usr/bin/python3",
           [
             script(),
             "--workspace-quota",
             Path.expand(workspace),
             to_string(limits.max_scratch_bytes)
           ],
           stderr_to_stdout: true
         ) do
      {"1\n", 0} -> :ok
      _ -> {:error, {:invalid_workspace, :bounded_tmpfs_required}}
    end
  end

  defp pdf_pages(input, dir, limits, started) do
    with {:ok, info, diag} <- command("pdfinfo", [input], dir, limits, started),
         [_, count] <- Regex.run(~r/^Pages:\s+(\d+)$/m, info),
         count = String.to_integer(count),
         :ok <- validate_pages(count, limits),
         false <- Regex.match?(~r/^Encrypted:\s+yes/im, info) do
      {:ok, count, diag}
    else
      nil -> {:error, {:invalid_pdf, :missing_page_count}}
      true -> {:error, {:authentication_failure, :encrypted_pdf}}
      error -> error
    end
  end

  defp exact_page(1), do: :ok
  defp exact_page(_), do: {:error, {:invalid_pdf, :subset_page_count}}

  defp bounded_pdf(path, max_bytes) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: bytes}} when bytes > 0 and bytes <= max_bytes ->
        File.chmod(path, 0o600)

      {:ok, %{type: :regular, size: bytes}} when bytes > max_bytes ->
        {:error, {:processor_limit, :output_bytes}}

      _ ->
        {:error, {:invalid_pdf, :output_file}}
    end
  end

  defp extract_ocr(input, page, dir, limits, started) do
    subset = Path.join(dir, "subset.pdf")
    pdf = Path.join(dir, "ocr.pdf")
    text = Path.join(dir, "ocr.text")

    with {:ok, count, input_diag} <- pdf_pages(input, dir, limits, started),
         true <- page <= count || {:error, {:invalid_pdf, :original_page}},
         {:ok, _, subset_diag} <-
           command(
             "qpdf",
             [input, "--pages", input, to_string(page), "--", subset],
             dir,
             %{limits | max_output_bytes: min(limits.max_subset_bytes, limits.max_output_bytes)},
             started
           ),
         :ok <- bounded_pdf(subset, min(limits.max_subset_bytes, limits.max_output_bytes)),
         {:ok, subset_count, subset_info_diag} <- pdf_pages(subset, dir, limits, started),
         :ok <- exact_page(subset_count),
         {:ok, _, ocr_diag} <-
           command("ocrmypdf", @ocr_flags ++ [subset, pdf], dir, limits, started),
         :ok <- bounded_pdf(pdf, limits.max_output_bytes),
         {:ok, ocr_count, ocr_info_diag} <- pdf_pages(pdf, dir, limits, started),
         :ok <- exact_page(ocr_count),
         {:ok, _, text_diag} <- command("pdftotext", ["-layout", pdf, text], dir, limits, started),
         :ok <- File.chmod(text, 0o600),
         {:ok, quality} <-
           assess(text, 1, Map.put(limits, :deadline_ms, started + limits.wall_time_ms)),
         versions = ocr_versions(dir, limits, started),
         :ok <- deadline(limits, started),
         true <-
           Enum.all?(versions, fn {_, version} -> version != "unavailable" end) ||
             {:error, {:processor_unavailable, :ocr_tools}} do
      output = %{"page_count" => 1, "original_pages" => [page], "quality_measurements" => quality}

      {:ok,
       %{
         text_path: text,
         searchable_pdf_path: pdf,
         text_byte_size: File.stat!(text).size,
         pdf_byte_size: File.stat!(pdf).size,
         page_count: 1,
         original_pages: [page],
         quality_measurements: quality,
         output: output,
         tool_versions: versions,
         diagnostics:
           Map.new(
             [
               {"input_pdfinfo", input_diag},
               {"qpdf", subset_diag},
               {"subset_pdfinfo", subset_info_diag},
               {"ocrmypdf", ocr_diag},
               {"ocr_pdfinfo", ocr_info_diag},
               {"pdftotext", text_diag}
             ],
             fn {k, v} -> {k, safe_diag(v)} end
           ),
         cpu_ms: invocation_cpu_ms(dir),
         duration_ms: System.monotonic_time(:millisecond) - started
       }}
    end
  end

  defp limits(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(opts, fn {k, v} ->
           is_map_key(@defaults, k) and is_integer(v) and v > 0 and v <= Map.fetch!(@defaults, k)
         end) do
      {:ok, Map.merge(@defaults, Map.new(opts))}
    else
      {:error, {:invalid_pdf_limits, :options}}
    end
  end

  defp validate_workspace(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory, mode: mode}} ->
        if Bitwise.band(mode, 0o777) == 0o700,
          do: :ok,
          else: {:error, {:invalid_workspace, :private_directory_required}}

      _ ->
        {:error, {:invalid_workspace, :private_directory_required}}
    end
  end

  defp random_id, do: Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

  defp versions(
         dir,
         probe_limits \\ %{
           @defaults
           | wall_time_ms: 5_000,
             cpu_seconds: 5,
             max_diagnostic_bytes: 4096
         },
         started \\ System.monotonic_time(:millisecond)
       ) do
    Map.new(["pdfinfo", "pdftotext", "python3"], fn tool ->
      flag = if tool == "python3", do: "--version", else: "-v"

      regex =
        if tool == "python3",
          do: ~r/Python 3\.[0-9]+\.[0-9]+/,
          else: ~r/#{tool} version [0-9]+(?:\.[0-9]+)+/

      value =
        case command(tool, [flag], dir, probe_limits, started) do
          {:ok, out, diag} ->
            data = out <> File.read!(diag.stderr_path)

            case Regex.run(regex, data) do
              [value] -> value
              _ -> "unavailable"
            end

          {:error, {:processor_limit, _} = reason} ->
            throw(reason)

          _ ->
            "unavailable"
        end

      {tool, value}
    end)
  end

  defp validate_input(%{media_type: media, sha256: hash, byte_size: bytes}, path, limits) do
    with true <- media == "application/pdf" || {:error, {:unsupported_media, media}},
         {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular || {:error, {:invalid_pdf, :not_regular_file}},
         true <- stat.size <= limits.max_input_bytes || {:error, {:oversized_pdf, :byte_limit}},
         true <- stat.size == bytes || {:error, {:invalid_pdf, :byte_size}},
         {:ok, file} <- :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      try do
        case :file.read(file, 5) do
          {:ok, "%PDF-"} ->
            context = :crypto.hash_update(:crypto.hash_init(:sha256), "%PDF-")

            with {:ok, context, size} <- checksum(file, context, 5, limits),
                 {:ok, after_stat} <- File.lstat(path) do
              actual = Base.encode16(:crypto.hash_final(context), case: :lower)

              cond do
                after_stat.type != :regular or after_stat.inode != stat.inode ->
                  {:error, {:invalid_pdf, :input_file}}

                size != bytes or after_stat.size != bytes ->
                  {:error, {:invalid_pdf, :byte_size}}

                actual != hash ->
                  {:error, {:invalid_pdf, :checksum}}

                true ->
                  :ok
              end
            end

          _ ->
            {:error, {:invalid_pdf, :signature}}
        end
      after
        :file.close(file)
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, {:invalid_pdf, :input_file}}
      error -> error
    end
  end

  defp validate_input(_, _, _), do: {:error, {:invalid_pdf, :input_metadata}}

  defp checksum(file, context, size, limits) do
    cond do
      size > limits.max_input_bytes ->
        {:error, {:oversized_pdf, :byte_limit}}

      System.monotonic_time(:millisecond) >= limits.deadline_ms ->
        {:error, {:processor_limit, :wall_time}}

      true ->
        case :file.read(file, 65_536) do
          {:ok, chunk} ->
            checksum(file, :crypto.hash_update(context, chunk), size + byte_size(chunk), limits)

          :eof ->
            {:ok, context, size}

          _ ->
            {:error, {:invalid_pdf, :input_file}}
        end
    end
  end

  defp extract(input, dir, limits, started) do
    text_path = Path.join(dir, "native.text")

    with {:ok, info, info_diag} <- command("pdfinfo", [input], dir, limits, started),
         [_, count] <- Regex.run(~r/^Pages:\s+(\d+)$/m, info),
         page_count = String.to_integer(count),
         :ok <- validate_pages(page_count, limits),
         false <- Regex.match?(~r/^Encrypted:\s+yes/im, info),
         {:ok, _, text_diag} <-
           command("pdftotext", ["-layout", input, text_path], dir, limits, started),
         :ok <- File.chmod(text_path, 0o600),
         {:ok, quality} <-
           assess(
             text_path,
             page_count,
             Map.put(limits, :deadline_ms, started + limits.wall_time_ms)
           ),
         versions = versions(dir, limits, started),
         :ok <- deadline(limits, started),
         true <- Enum.all?(versions, fn {_, value} -> value != "unavailable" end) do
      {:ok,
       %{
         text_path: text_path,
         text_byte_size: File.stat!(text_path).size,
         page_count: page_count,
         quality_measurements: quality,
         output: %{"page_count" => page_count, "quality_measurements" => quality},
         diagnostics: %{"pdfinfo" => safe_diag(info_diag), "pdftotext" => safe_diag(text_diag)},
         tool_versions: versions,
         cpu_ms: invocation_cpu_ms(dir),
         duration_ms: System.monotonic_time(:millisecond) - started
       }}
    else
      nil -> {:error, {:invalid_pdf, :missing_page_count}}
      true -> {:error, {:authentication_failure, :encrypted_pdf}}
      false -> {:error, {:processor_unavailable, :poppler}}
      error -> error
    end
  end

  defp validate_pages(count, limits) do
    cond do
      count <= 0 -> {:error, {:invalid_pdf, :page_count}}
      count > limits.max_pages -> {:error, {:oversized_pdf, :page_limit}}
      true -> :ok
    end
  end

  defp deadline(limits, started) do
    if System.monotonic_time(:millisecond) - started >= limits.wall_time_ms,
      do: {:error, {:processor_limit, :wall_time}},
      else: :ok
  end

  defp command(tool, args, dir, limits, started) do
    with :ok <- deadline(limits, started) do
      run_command(tool, args, dir, limits, started)
    end
  end

  defp script do
    case :code.priv_dir(:brussels_wtf) do
      path when is_list(path) ->
        candidate = Path.join(to_string(path), "pdf/bounded_command.py")
        if File.regular?(candidate), do: candidate, else: @script

      _ ->
        @script
    end
  end

  defp run_command(tool, args, dir, limits, started) do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    out = Path.join(dir, id <> ".stdout")
    err = Path.join(dir, id <> ".stderr")
    wall = max(1, limits.wall_time_ms - (System.monotonic_time(:millisecond) - started))

    argv =
      [
        script(),
        out,
        err,
        to_string(wall),
        to_string(limits.cpu_seconds),
        to_string(limits.memory_bytes),
        to_string(limits.max_output_bytes),
        to_string(limits.max_diagnostic_bytes)
      ] ++
        ["--caller-stdin", "--budget", Path.join(dir, "cpu.budget")] ++
        if(Map.has_key?(limits, :scratch_dir), do: ["--scratch", limits.scratch_dir], else: []) ++
        ["/usr/bin/" <> tool] ++ args

    {protocol, _} = System.cmd("/usr/bin/python3", argv, stderr_to_stdout: true)

    [status, limit, stdout, stderr, duration, rss, cpu] =
      protocol |> String.trim() |> String.split() |> Enum.map(&String.to_integer/1)

    diag = %{
      status: status,
      limit: limit,
      stdout_bytes: stdout,
      stderr_bytes: stderr,
      duration_ms: duration,
      peak_rss_kib: rss,
      cpu_ms: cpu,
      stderr_path: err
    }

    private =
      case File.read(err) do
        {:ok, bytes} -> String.downcase(bytes)
        {:error, _} -> ""
      end

    cond do
      limit == 1 ->
        {:error, {:processor_limit, :wall_time}}

      limit == 2 ->
        {:error, {:processor_limit, :diagnostics}}

      limit == 3 ->
        {:error, {:processor_unavailable, tool}}

      limit == 4 ->
        {:error, {:processor_limit, :scratch_bytes}}

      limit == 5 ->
        {:error, {:processor_limit, :cpu}}

      limit == 6 ->
        {:error, {:processor_failed, :caller_cancelled}}

      status == -25 ->
        {:error, {:processor_limit, :output_bytes}}

      status == -24 or (status == -9 and cpu >= limits.cpu_seconds * 1000) ->
        {:error, {:processor_limit, :cpu}}

      status == -9 ->
        {:error, {:processor_limit, :memory_or_kill}}

      Map.has_key?(limits, :scratch_dir) and
          String.contains?(private, ["no space left on device", "disk quota exceeded"]) ->
        {:error, {:processor_limit, :scratch_bytes}}

      status != 0 ->
        cond do
          String.contains?(private, [
            "failed to map segment",
            "cannot allocate memory",
            "memoryerror"
          ]) ->
            {:error, {:processor_limit, :memory}}

          String.contains?(private, "password") ->
            {:error, {:authentication_failure, :encrypted_pdf}}

          String.contains?(private, "syntax error") ->
            {:error, {:invalid_pdf, :syntax}}

          true ->
            {:error, {:processor_failed, {tool, status}}}
        end

      true ->
        {:ok, File.read!(out), diag}
    end
  rescue
    _ -> {:error, {:processor_unavailable, tool}}
  end

  defp safe_diag(diag), do: Map.delete(diag, :stderr_path)

  defp assess(path, count, limits), do: BrusselsWtf.PDF.FileQuality.assess(path, count, limits)
end
