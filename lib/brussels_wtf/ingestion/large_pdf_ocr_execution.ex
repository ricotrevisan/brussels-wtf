defmodule BrusselsWtf.Ingestion.LargePdfOcrExecution do
  @moduledoc false
  alias BrusselsWtf.{Ingestion, Review, Repo, Archive}
  alias BrusselsWtf.Ingestion.{LargePdfOcrRecovery, OcrRecoveryBudget, ProcessingRun}
  alias BrusselsWtf.PDF.{FileProcessor, FileQuality}
  require Ash.Query
  @store_ms 750_000
  @page_transaction_ms 1_725_000
  @assembly_transaction_ms 4_815_000
  # At most 64 checkpoint GETs (32 text/PDF pairs), one native GET,
  # a 750s verified store, and one shared 120s validation envelope.
  @checkpoint_ms 3_960_000
  # Worst job: completed-checkpoint replay + one page + final assembly.
  @guard_ms @checkpoint_ms + @page_transaction_ms + @assembly_transaction_ms
  @max_text 67_108_864
  @max_page 262_144
  # One database-wide workspace execution guard, shared by all OCR consumer nodes.
  @workspace_lock 1_203_121_079

  @doc false
  def execution_budget,
    do: %{
      archive_store_ms: @store_ms,
      page_transaction_ms: @page_transaction_ms,
      checkpoint_ms: @checkpoint_ms,
      assembly_transaction_ms: @assembly_transaction_ms,
      guard_ms: @guard_ms,
      worker_ms: @guard_ms + 30_000,
      cpu_ms: 90_000,
      processing_wall_ms: 120_000
    }

  @doc false
  def guard_connection_options(config) do
    Keyword.take(config, [
      :hostname,
      :endpoints,
      :port,
      :username,
      :password,
      :database,
      :ssl,
      :ssl_opts,
      :socket_options,
      :socket,
      :socket_dir,
      :parameters,
      :connect_timeout,
      :handshake_timeout,
      :timeout,
      :ping_timeout,
      :prepare,
      :types,
      :disconnect_on_error_codes
    ])
  end

  def execute(id, attempt) do
    if Application.get_env(:brussels_wtf, :process_role) != :ocr do
      {:discard, "large OCR requires isolated OCR role"}
    else
      config = guard_connection_options(Repo.config())

      # Dedicated linked connection: caller/VM death closes the transaction lock.
      # No domain SQL writes occur here. Budget reservations commit on Repo first.
      {:ok, guard} = Postgrex.start_link(config)

      try do
        case Postgrex.transaction(
               guard,
               fn connection ->
                 case Postgrex.query!(connection, "SELECT pg_try_advisory_xact_lock($1)", [
                        @workspace_lock
                      ]).rows do
                   [[true]] ->
                     Process.put(:large_ocr_guard_connection, connection)
                     Repo.checkout(fn -> execute_guarded(id, attempt) end, timeout: @guard_ms)

                   _ ->
                     {:error, :ocr_workspace_busy}
                 end
               end,
               timeout: @guard_ms
             ) do
          {:ok, result} -> result
          _ -> {:error, :ocr_recovery_unavailable}
        end
      after
        Process.delete(:large_ocr_guard_connection)
        if Process.alive?(guard), do: GenServer.stop(guard)
      end
    end
  rescue
    _ -> {:error, :ocr_recovery_unavailable}
  catch
    _, _ -> {:error, :ocr_recovery_unavailable}
  end

  defp execute_guarded(id, attempt) do
    run = Ingestion.get_processing_run!(id) |> Ash.load!(source_version: [:source_record])

    if valid_generation?(run) do
      workspace =
        Application.get_env(:brussels_wtf, :large_pdf_ocr_workspace, "/app/large-pdf-ocr-scratch")

      case FileProcessor.validate_ocr_workspace(workspace) do
        :ok ->
          case clean_workspace(workspace) do
            :ok ->
              try do
                execute_admitted(run, workspace, attempt)
              after
                clean_workspace(workspace)
              end

            _ ->
              availability_failure(run, attempt)
          end

        _ ->
          availability_failure(run, attempt)
      end
    else
      {:discard, "not an audited held OCR generation"}
    end
  end

  defp valid_generation?(run) do
    audit =
      Ash.get!(Review.Action, run.inputs["review_action_id"], authorize?: false, error?: false)

    review_case =
      Ash.get!(Review.Case, run.inputs["review_case_id"], authorize?: false, error?: false)

    native = Ingestion.get_processing_run!(run.inputs["native_run_id"])

    is_map(audit) and is_map(review_case) and run.processor_role == :ocr and
      run.inputs["operation"] == "ocr_large_pages" and run.inputs["extraction_only"] == true and
      run.generation_key == "review:#{audit.id}" and audit.review_case_id == review_case.id and
      audit.action == :retry and audit.effect == :processing_generation and
      audit.details["operation"] == "ocr_large_pages" and audit.details["extraction_only"] == true and
      audit.details["sha256"] == run.source_version.sha256 and
      audit.details["source_version_id"] == run.source_version_id and
      audit.details["native_run_id"] == native.id and
      audit.details["original_pages"] == run.inputs["original_pages"] and
      audit.details["processor_name"] == run.processor_name and
      audit.details["processor_version"] == run.processor_version and
      audit.details["config_hash"] == run.config_hash and
      audit.details["tool_versions"] == run.tool_versions and
      LargePdfOcrRecovery.eligible_native?(
        native,
        %{review_case | status: :open},
        run.source_version,
        run.inputs["original_pages"]
      )
  rescue
    _ -> false
  end

  defp chunks(run) do
    ProcessingRun
    |> Ash.Query.filter(inputs[:parent_run_id] == ^run.id)
    |> Ash.read!()
    |> Enum.sort_by(& &1.inputs["original_pages"])
    |> Ash.load!(:derived_artifacts)
  end

  defp valid_chunks?(run, chunks) do
    Enum.map(chunks, & &1.inputs["original_pages"]) ==
      Enum.map(run.inputs["original_pages"], &[&1]) and
      Enum.all?(chunks, fn chunk ->
        chunk.source_version_id == run.source_version_id and
          chunk.processor_name == run.processor_name and
          chunk.processor_version == run.processor_version and
          chunk.config_hash == run.config_hash and
          chunk.inputs["extraction_only"] == true and
          chunk.inputs["source_sha256"] == run.source_version.sha256 and
          chunk.generation_key ==
            "#{run.generation_key}:page:#{hd(chunk.inputs["original_pages"])}"
      end)
  end

  defp execute_admitted(%{status: :failed}, _, _), do: :ok

  defp execute_admitted(%{status: :succeeded} = run, workspace, _) do
    transaction(
      fn ->
        artifacts = Ash.load!(run, :derived_artifacts).derived_artifacts

        with [artifact] <- artifacts,
             "ocr-text" <- artifact.output_kind,
             :ok <- lineage(artifact, run),
             {:ok, _} <-
               bounded_io(
                 fn -> fetch(artifact, owned_path(workspace, "replay.txt"), @max_text) end,
                 60_000
               ),
             :ok <- verify_chunks(run, chunks(run), workspace) do
          {:ok, []}
        else
          _ ->
            {{:discard, "completed OCR artifacts failed verification"},
             open_case(run, "corruption")}
        end
      end,
      @assembly_transaction_ms
    )
  end

  defp execute_admitted(run, workspace, attempt) do
    chunks = chunks(run)

    cond do
      not valid_chunks?(run, chunks) ->
        fail_parent(run, "invalid_content")

      Enum.any?(chunks, &(&1.status == :failed)) ->
        fail_parent(run, "resource_limit")

      verify_completed_chunks(run, chunks, workspace) != :ok ->
        fail_parent(run, "corruption")

      true ->
        case Enum.find(chunks, &(&1.status == :queued)) do
          nil ->
            assemble(run, chunks, workspace)

          chunk ->
            budget =
              OcrRecoveryBudget
              |> Ash.Query.filter(processing_run_id == ^run.id)
              |> Ash.read_one!()

            token = Ecto.UUID.generate()

            case Ingestion.reserve_ocr_recovery_budget(
                   budget,
                   %{page_run_id: chunk.id, token: token},
                   return_notifications?: true
                 ) do
              {:ok, reserved, notifications} ->
                Ash.Notifier.notify(notifications)
                process_page(run, chunk, reserved, token, workspace, attempt)

              _ ->
                fail_parent(run, "resource_limit")
            end
        end
    end
  end

  defp process_page(run, chunk, budget, token, workspace, _attempt) do
    reservation = budget.reservations[token]
    page = hd(chunk.inputs["original_pages"])
    started = System.monotonic_time(:millisecond)

    result =
      transaction(
        fn ->
          Repo.query!("SET LOCAL lock_timeout = '15s'")

          current =
            ProcessingRun
            |> Ash.Query.filter(id == ^chunk.id)
            |> Ash.Query.lock(:for_update)
            |> Ash.read_one!()

          if current.status != :queued, do: Repo.rollback(:stale_claim)

          result =
            bounded_io(
              fn ->
                input = owned_path(workspace, "source.pdf")

                with {:ok, _} <-
                       Archive.fetch_file(
                         run.source_version.object_key,
                         run.source_version.sha256,
                         run.source_version.byte_size,
                         input,
                         max_bytes: 167_772_160,
                         timeout_ms: 60_000,
                         receive_timeout_ms: 15_000
                       ),
                     {:ok, result, cpu, wall} <- invoke(run, page, input, workspace, reservation),
                     true <-
                       budget.output_bytes + result.text_byte_size + result.pdf_byte_size <=
                         134_217_728,
                     {:ok, text_archive} <-
                       bounded_io(
                         fn -> Archive.store_file(result.text_path, :derived) end,
                         @store_ms,
                         false
                       ),
                     {:ok, pdf_archive} <-
                       bounded_io(
                         fn -> Archive.store_file(result.searchable_pdf_path, :derived) end,
                         @store_ms,
                         false
                       ) do
                  {:ok, result, text_archive, pdf_archive, cpu, wall}
                else
                  {:error, :configuration_mismatch} -> {:error, "configuration_mismatch"}
                  {:error, {:hash_mismatch, _, _}} -> {:error, "corruption"}
                  {:error, {:size_mismatch, _, _}} -> {:error, "corruption"}
                  _ -> {:error, "resource_limit"}
                end
              end,
              1_680_000
            )

          case result do
            {:ok, output, text_archive, pdf_archive, cpu, wall} ->
              accounted = Map.merge(output, %{cpu_ms: cpu, duration_ms: wall})

              notifications =
                persist_page(
                  run,
                  current,
                  accounted,
                  text_archive,
                  pdf_archive,
                  reservation["attempt"]
                )

              {_, budget_notifications} =
                Ingestion.settle_ocr_recovery_budget!(
                  budget,
                  %{
                    token: token,
                    cpu_ms: cpu,
                    wall_ms: wall,
                    output_bytes: output.text_byte_size + output.pdf_byte_size
                  },
                  return_notifications?: true
                )

              {:ok, notifications ++ budget_notifications}

            error ->
              classification =
                case error do
                  {:error, value} when value in ["configuration_mismatch", "corruption"] -> value
                  _ -> "resource_limit"
                end

              notifications =
                persist_failure(
                  current,
                  run,
                  classification,
                  reservation["attempt"],
                  System.monotonic_time(:millisecond) - started
                )

              {:ok, notifications}
          end
        end,
        @page_transaction_ms
      )

    case result do
      :ok ->
        chunks = chunks(run)

        if Enum.all?(chunks, &(&1.status == :succeeded)) do
          clean_workspace(workspace)
          assemble(run, chunks, workspace)
        else
          if Enum.any?(chunks, &(&1.status == :failed)) do
            :ok
          else
            %{processing_run_id: run.id}
            |> BrusselsWtf.Workers.OcrLargeSource.new()
            |> Oban.insert!()

            :ok
          end
        end

      other ->
        other
    end
  end

  defp invoke(run, page, input, workspace, reservation) do
    start = System.monotonic_time(:millisecond)
    cpu = reservation["cpu_ms"]
    wall = reservation["wall_ms"]
    processor = LargePdfOcrRecovery.processor()
    metadata = processor.ocr_metadata_accounted(cpu_seconds: div(cpu, 1000), wall_time_ms: wall)
    used_wall = System.monotonic_time(:millisecond) - start
    remaining_cpu = div(cpu - metadata.cpu_ms, 1000)
    remaining_wall = wall - used_wall

    if metadata.ocr_processor_name == run.processor_name and
         metadata.ocr_processor_version == run.processor_version and
         metadata.config_hash == run.config_hash and metadata.tool_versions == run.tool_versions and
         is_integer(metadata.cpu_ms) and metadata.cpu_ms >= 0 and remaining_cpu >= 1 and
         remaining_wall > 0 do
      meta = %{
        sha256: run.source_version.sha256,
        media_type: run.source_version.media_type,
        byte_size: run.source_version.byte_size
      }

      case processor.ocr_page(meta, input, page, workspace,
             cpu_seconds: remaining_cpu,
             wall_time_ms: remaining_wall
           ) do
        {:ok, result} ->
          validation = validate_result(result, page, workspace, start + wall)
          wall_used = max(1, System.monotonic_time(:millisecond) - start)
          total_cpu = metadata.cpu_ms + result.cpu_ms

          if validation == :ok and is_integer(result.cpu_ms) and result.cpu_ms >= 0 and
               total_cpu <= cpu and wall_used <= wall and
               result.tool_versions == run.tool_versions,
             do: {:ok, result, total_cpu, wall_used},
             else: {:error, :invalid_accounting}

        _ ->
          {:error, :processor_failed}
      end
    else
      {:error, :configuration_mismatch}
    end
  end

  defp validate_result(result, page, workspace, deadline) do
    limits = Map.put(quality_limits(1), :deadline_ms, deadline)

    with 1 <- result.page_count,
         [^page] <- result.original_pages,
         :ok <- private_output(result.text_path, workspace, result.text_byte_size, @max_page + 1),
         :ok <-
           private_output(result.searchable_pdf_path, workspace, result.pdf_byte_size, @max_text),
         {:ok, quality} <- FileQuality.assess(result.text_path, 1, limits),
         true <- quality == result.quality_measurements do
      :ok
    else
      _ -> {:error, :invalid_result}
    end
  end

  defp private_output(path, workspace, expected, cap) do
    with true <- String.starts_with?(Path.expand(path), Path.expand(workspace) <> "/"),
         {:ok, %{type: :regular, size: size}} <- File.lstat(path),
         true <- size == expected and size > 0 and size <= cap do
      :ok
    else
      _ -> {:error, :invalid_output}
    end
  end

  defp persist_page(run, chunk, output, text_archive, pdf_archive, attempt) do
    completed_at = BrusselsWtf.Clock.utc_now()
    started_at = DateTime.add(completed_at, -output.duration_ms, :millisecond)

    {_, run_notifications} =
      Ingestion.complete_processing_run!(
        chunk,
        %{
          status: :succeeded,
          started_at: started_at,
          completed_at: completed_at,
          quality_measurements: output.quality_measurements,
          tool_versions: output.tool_versions,
          output: %{
            "original_pages" => chunk.inputs["original_pages"],
            "page_count" => 1,
            "text_sha256" => text_archive.sha256,
            "pdf_sha256" => pdf_archive.sha256
          },
          diagnostics: %{"cpu_ms" => output.cpu_ms},
          duration_ms: output.duration_ms
        },
        return_notifications?: true
      )

    {_, attempt_notifications} =
      Ingestion.record_processing_attempt!(
        %{
          processing_run_id: chunk.id,
          attempt: attempt,
          status: :succeeded,
          started_at: started_at,
          completed_at: completed_at,
          quality_measurements: output.quality_measurements,
          duration_ms: output.duration_ms,
          diagnostics: %{"cpu_ms" => output.cpu_ms}
        },
        return_notifications?: true
      )

    notifications =
      archive_artifact(
        chunk,
        text_archive,
        "ocr-page-text",
        "text/plain; charset=utf-8",
        output.quality_measurements,
        :ocr_output
      ) ++
        archive_artifact(
          chunk,
          pdf_archive,
          "ocr-page-pdf",
          "application/pdf",
          output.quality_measurements,
          :ocr_document
        )

    quality_notifications =
      if output.quality_measurements["accepted"], do: [], else: open_case(run, "quality_rejected")

    run_notifications ++ attempt_notifications ++ notifications ++ quality_notifications
  end

  defp archive_artifact(run, archived, kind, media, quality, role) do
    {artifact, notifications} =
      Ingestion.upsert_derived_artifact!(
        %{
          source_version_id: run.source_version_id,
          processing_run_id: run.id,
          input_sha256: run.inputs["source_sha256"],
          output_sha256: archived.sha256,
          object_key: archived.object_key,
          byte_size: archived.byte_size,
          processor_name: run.processor_name,
          processor_version: run.processor_version,
          config_hash: run.config_hash,
          output_kind: kind,
          media_type: media,
          schema_version: "derived-artifact-v1",
          quality_measurements: quality
        },
        return_notifications?: true
      )

    {_, links} =
      Ingestion.link_processing_run_artifact!(
        %{processing_run_id: run.id, derived_artifact_id: artifact.id, role: role},
        return_notifications?: true
      )

    notifications ++ links
  end

  defp assemble(run, chunks, workspace) do
    budget =
      OcrRecoveryBudget |> Ash.Query.filter(processing_run_id == ^run.id) |> Ash.read_one!()

    token = Ecto.UUID.generate()

    case Ingestion.reserve_ocr_assembly_budget(budget, %{token: token},
           return_notifications?: true
         ) do
      {:ok, reserved, notifications} ->
        Ash.Notifier.notify(notifications)
        assemble_reserved(run, chunks, workspace, reserved, token)

      _ ->
        fail_parent(run, "resource_limit")
    end
  end

  defp assemble_reserved(run, chunks, workspace, budget, token) do
    allowance = budget.reservations[token]["wall_ms"]

    transaction(
      fn ->
        Repo.query!("SET LOCAL lock_timeout = '15s'")

        locked =
          ProcessingRun
          |> Ash.Query.filter(id == ^run.id)
          |> Ash.Query.lock(:for_update)
          |> Ash.read_one!()

        if locked.status != :queued, do: Repo.rollback(:stale_parent)

        native =
          Ingestion.get_processing_run!(run.inputs["native_run_id"])
          |> Ash.load!(:derived_artifacts)

        result =
          bounded_io(
            fn ->
              with true <-
                     valid_chunks?(run, chunks) and Enum.all?(chunks, &(&1.status == :succeeded)),
                   [native_artifact] <-
                     Enum.filter(native.derived_artifacts, &(&1.output_kind == "native-text")),
                   :ok <- lineage(native_artifact, native),
                   native_path = owned_path(workspace, "native.txt"),
                   {:ok, _} <- fetch(native_artifact, native_path, @max_text),
                   {:ok, native_quality, native_ms} <-
                     assess_with_cost(
                       native_path,
                       native.quality_measurements["page_count"],
                       allowance
                     ),
                   true <- native_quality == native.quality_measurements,
                   {:ok, replacements} <- retained_pages(run, chunks, workspace),
                   output_path = owned_path(workspace, "assembled.txt"),
                   {:ok, quality, assembly_ms} <-
                     bounded_io(
                       fn ->
                         started = System.monotonic_time(:millisecond)

                         with :ok <-
                                BrusselsWtf.PDF.PageAssembly.assemble(
                                  native_path,
                                  replacements,
                                  output_path,
                                  native_quality["page_count"]
                                ),
                              {:ok, q} <-
                                FileQuality.assess(
                                  output_path,
                                  native_quality["page_count"],
                                  Map.put(
                                    quality_limits(500),
                                    :deadline_ms,
                                    started + allowance - native_ms
                                  )
                                ) do
                           {:ok, q, max(1, System.monotonic_time(:millisecond) - started)}
                         end
                       end,
                       max(1, allowance - native_ms),
                       false
                     ),
                   true <- native_ms + assembly_ms <= allowance,
                   {:ok, archived} <-
                     bounded_io(
                       fn -> Archive.store_file(output_path, :derived) end,
                       @store_ms,
                       false
                     ) do
                {:ok, archived, quality, native_ms + assembly_ms}
              else
                _ -> {:error, :incomplete_artifact}
              end
            end,
            @assembly_transaction_ms - 45_000
          )

        case result do
          {:ok, archived, quality, used_wall} ->
            {settled, budget_notifications} =
              Ingestion.settle_ocr_recovery_budget!(
                budget,
                %{token: token, cpu_ms: 0, wall_ms: used_wall, output_bytes: 0},
                return_notifications?: true
              )

            budget = settled

            {_, notifications} =
              Ingestion.complete_processing_run!(
                run,
                %{
                  status: :succeeded,
                  started_at: Enum.min_by(chunks, & &1.started_at, DateTime).started_at,
                  completed_at: BrusselsWtf.Clock.utc_now(),
                  duration_ms: budget.wall_ms,
                  quality_measurements: quality,
                  output: %{
                    "page_count" => quality["page_count"],
                    "original_pages" => run.inputs["original_pages"],
                    "native_run_id" => native.id,
                    "text_sha256" => archived.sha256,
                    "chunk_run_ids" => Enum.map(chunks, & &1.id),
                    "page_manifest" => page_manifest(native, chunks),
                    "cpu_ms" => budget.cpu_ms,
                    "processing_wall_ms" => budget.wall_ms
                  }
                },
                return_notifications?: true
              )

            artifacts =
              archive_artifact(
                run,
                archived,
                "ocr-text",
                "text/plain; charset=utf-8",
                quality,
                :ocr_output
              )

            cases =
              if quality["accepted"] do
                {_, n} = Review.complete_retry_with_notifications!(run.inputs["review_case_id"])
                n
              else
                open_case(run, "quality_rejected")
              end

            {:ok, notifications ++ artifacts ++ cases ++ budget_notifications}

          _ ->
            {:ok, persist_failure(run, run, "corruption", 1, 0)}
        end
      end,
      @assembly_transaction_ms
    )
  end

  defp page_manifest(native, chunks) do
    by_page = Map.new(chunks, &{hd(&1.inputs["original_pages"]), &1})

    for page <- 1..native.quality_measurements["page_count"] do
      case by_page[page] do
        nil ->
          %{
            "original_page" => page,
            "origin" => "native",
            "processing_run_id" => native.id,
            "local_page" => page
          }

        chunk ->
          %{
            "original_page" => page,
            "origin" => "ocr",
            "processing_run_id" => chunk.id,
            "local_page" => 1,
            "text_sha256" => chunk.output["text_sha256"],
            "pdf_sha256" => chunk.output["pdf_sha256"]
          }
      end
    end
  end

  defp retained_pages(run, chunks, workspace) do
    if valid_chunks?(run, chunks) do
      Enum.reduce_while(chunks, {:ok, %{}}, fn chunk, {:ok, pages} ->
        page = hd(chunk.inputs["original_pages"])
        artifacts = chunk.derived_artifacts
        text_path = owned_path(workspace, "page-#{page}.txt")
        pdf_path = owned_path(workspace, "page-#{page}.pdf")

        with [text] <- Enum.filter(artifacts, &(&1.output_kind == "ocr-page-text")),
             [pdf] <- Enum.filter(artifacts, &(&1.output_kind == "ocr-page-pdf")),
             true <- length(artifacts) == 2,
             :ok <- lineage(text, chunk),
             :ok <- lineage(pdf, chunk),
             true <-
               text.output_sha256 == chunk.output["text_sha256"] and
                 pdf.output_sha256 == chunk.output["pdf_sha256"] and
                 chunk.output["original_pages"] == [page],
             {:ok, _} <- fetch(text, text_path, @max_page + 1),
             {:ok, _} <- fetch(pdf, pdf_path, @max_text) do
          File.rm!(pdf_path)
          {:cont, {:ok, Map.put(pages, page, text_path)}}
        else
          _ -> {:halt, {:error, :checkpoint_corruption}}
        end
      end)
    else
      {:error, :page_map}
    end
  end

  defp verify_completed_chunks(run, chunks, workspace) do
    completed = Enum.filter(chunks, &(&1.status == :succeeded))

    subset = %{
      run
      | inputs:
          Map.put(
            run.inputs,
            "original_pages",
            Enum.flat_map(completed, & &1.inputs["original_pages"])
          )
    }

    result = verify_chunks(subset, completed, workspace)
    if result == :ok, do: clean_workspace(workspace)
    result
  end

  defp verify_chunks(run, chunks, workspace) do
    case bounded_io(fn -> retained_pages(run, chunks, workspace) end, @checkpoint_ms) do
      {:ok, _} -> :ok
      _ -> {:error, :checkpoint_corruption}
    end
  end

  defp lineage(artifact, run) do
    if artifact.input_sha256 == run.inputs["source_sha256"] and
         artifact.processor_name == run.processor_name and
         artifact.processor_version == run.processor_version and
         artifact.config_hash == run.config_hash and
         artifact.quality_measurements == run.quality_measurements,
       do: :ok,
       else: {:error, :lineage}
  end

  defp fetch(artifact, path, cap),
    do:
      Archive.fetch_file(artifact.object_key, artifact.output_sha256, artifact.byte_size, path,
        max_bytes: cap,
        timeout_ms: 60_000,
        receive_timeout_ms: 15_000
      )

  defp assess_with_cost(path, count, allowance) do
    started = System.monotonic_time(:millisecond)

    with {:ok, quality} <-
           FileQuality.assess(
             path,
             count,
             Map.put(quality_limits(500), :deadline_ms, started + allowance)
           ) do
      used = max(1, System.monotonic_time(:millisecond) - started)
      if used <= allowance, do: {:ok, quality, used}, else: {:error, :processing_wall_exhausted}
    end
  end

  defp quality_limits(max_pages),
    do: %{max_pages: max_pages, max_output_bytes: @max_text, max_page_bytes: @max_page}

  defp fail_parent(run, classification),
    do: transaction(fn -> {:ok, persist_failure(run, run, classification, 1, 0)} end, 30_000)

  defp persist_failure(chunk, run, classification, attempt, duration) do
    {_, n1} =
      Ingestion.complete_processing_run!(
        chunk,
        %{
          status: :failed,
          failure_classification: classification,
          diagnostics: %{"classification" => classification},
          duration_ms: duration
        },
        return_notifications?: true
      )

    {_, n2} =
      Ingestion.record_processing_attempt!(
        %{
          processing_run_id: chunk.id,
          attempt: attempt,
          status: :failed,
          started_at: BrusselsWtf.Clock.utc_now(),
          completed_at: BrusselsWtf.Clock.utc_now(),
          failure_classification: classification,
          diagnostics: %{"classification" => classification},
          duration_ms: duration
        },
        return_notifications?: true
      )

    parent_notifications =
      if chunk.id != run.id do
        {_, n} =
          Ingestion.complete_processing_run!(
            run,
            %{
              status: :failed,
              failure_classification: classification,
              diagnostics: %{"classification" => classification}
            },
            return_notifications?: true
          )

        n
      else
        []
      end

    n1 ++ n2 ++ parent_notifications ++ open_case(run, classification)
  end

  defp availability_failure(run, attempt) do
    transaction(
      fn ->
        id = run.id

        current =
          ProcessingRun
          |> Ash.Query.filter(id == ^id)
          |> Ash.Query.lock(:for_update)
          |> Ash.read_one!()

        if current.status != :queued do
          {:ok, []}
        else
          if attempt >= 3 do
            {:ok, persist_failure(run, run, "resource_limit", 3, 0)}
          else
            {_, notifications} =
              Ingestion.record_processing_attempt!(
                %{
                  processing_run_id: run.id,
                  attempt: max(attempt, 1),
                  status: :failed,
                  started_at: BrusselsWtf.Clock.utc_now(),
                  completed_at: BrusselsWtf.Clock.utc_now(),
                  duration_ms: 0,
                  failure_classification: "worker_unavailable",
                  diagnostics: %{"classification" => "worker_unavailable"}
                },
                return_notifications?: true
              )

            {{:error, :ocr_worker_unavailable}, notifications}
          end
        end
      end,
      30_000
    )
  end

  defp open_case(run, classification) do
    {_, notifications} =
      Review.open_review_case!(
        %{
          kind: :extraction,
          commune_id: run.source_version.source_record.commune_id,
          source_record_id: run.source_version.source_record_id,
          source_version_id: run.source_version_id,
          affected_record_id: run.source_version_id,
          affected_record_type: "source_version",
          processing_generation: "extraction:#{run.id}",
          urgency: :high,
          summary: "Page-selective OCR recovery remains extraction-only held",
          diagnostics: %{"classification" => classification},
          related_evidence: %{"processing_run_id" => run.id}
        },
        return_notifications?: true
      )

    notifications
  end

  defp transaction(fun, timeout) do
    case Repo.transaction(fun, timeout: timeout) do
      {:ok, {result, notifications}} ->
        Ash.Notifier.notify(notifications)
        result

      _ ->
        {:error, :ocr_recovery_unavailable}
    end
  end

  defp bounded_io(fun, timeout, heartbeat? \\ true) do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          _ -> {:error, :ocr_io_failed}
        catch
          _, _ -> {:error, :ocr_io_failed}
        end
      end)

    try do
      await(task, System.monotonic_time(:millisecond) + timeout, heartbeat?)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp await(task, deadline, heartbeat?) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :ocr_io_timeout}
    else
      case Task.yield(task, min(remaining, 1000)) do
        {:ok, result} ->
          if heartbeat?, do: heartbeat()
          result

        {:exit, _} ->
          {:error, :ocr_io_failed}

        nil ->
          if heartbeat?, do: heartbeat()
          await(task, deadline, heartbeat?)
      end
    end
  end

  defp heartbeat do
    Repo.query!("SELECT 1", [], timeout: 1000)
    Postgrex.query!(Process.get(:large_ocr_guard_connection), "SELECT 1", [], timeout: 1000)
  end

  defp owned_path(workspace, suffix),
    do: Path.join(workspace, "recovery-#{Ecto.UUID.generate()}-#{suffix}")

  defp clean_workspace(workspace) do
    entries = File.ls!(workspace)

    if length(entries) <= 1024 and Enum.all?(entries, &owned_entry?(workspace, &1)) and
         safe_tree?(
           Enum.map(entries, &{Path.join(workspace, &1), 0}),
           0,
           System.monotonic_time(:millisecond) + 5_000
         ) do
      Enum.each(entries, &File.rm_rf!(Path.join(workspace, &1)))
      :ok
    else
      {:error, :foreign_workspace_entries}
    end
  end

  defp owned_entry?(_workspace, name),
    do: Regex.match?(~r/\A(?:recovery-[0-9a-f-]{36}-.+|ocr-page-[0-9a-f-]{24,36})\z/, name)

  defp safe_tree?([], _, _), do: true

  defp safe_tree?([{path, depth} | rest], count, deadline) when count < 4096 and depth <= 8 do
    if System.monotonic_time(:millisecond) >= deadline do
      false
    else
      case File.lstat(path) do
        {:ok, %{type: :regular}} ->
          safe_tree?(rest, count + 1, deadline)

        {:ok, %{type: :directory}} ->
          children = File.ls!(path)

          length(children) + count <= 4096 and
            safe_tree?(
              Enum.map(children, &{Path.join(path, &1), depth + 1}) ++ rest,
              count + 1,
              deadline
            )

        _ ->
          false
      end
    end
  end

  defp safe_tree?(_, _, _), do: false
end
