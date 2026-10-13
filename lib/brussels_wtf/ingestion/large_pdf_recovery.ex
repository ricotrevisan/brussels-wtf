defmodule BrusselsWtf.Ingestion.LargePdfRecovery do
  @moduledoc "Explicit, audited native-only recovery. Every generation retains a downstream hold."
  alias BrusselsWtf.{Ingestion, Review, Repo}

  def processor,
    do: Application.get_env(:brussels_wtf, :large_pdf_processor, BrusselsWtf.PDF.FileProcessor)

  def metadata, do: processor().metadata()
  def held?(nil), do: false

  def held?(run),
    do: run.inputs["extraction_only"] == true or run.inputs["operation"] == "extract_large_native"

  def request(entries, note, opts) do
    actor = Keyword.get(opts, :actor)

    with :ok <- validate_options(opts),
         :ok <- validate_manifest(entries),
         {:ok, results} <-
           Repo.transaction(fn ->
             Enum.map(entries, fn entry ->
               review_case = Review.get_review_case!(entry.case_id, actor: actor)

               {result, notifications} =
                 Review.extract_large_native!(
                   review_case,
                   %{
                     note: note,
                     source_version_id: entry.source_version_id,
                     sha256: entry.sha256
                   },
                   actor: actor,
                   return_notifications?: true
                 )

               {Ingestion.get_processing_run!(result.__metadata__.large_processing_run_id),
                notifications}
             end)
           end) do
      Enum.each(results, fn {_run, notifications} -> Ash.Notifier.notify(notifications) end)
      {:ok, Enum.map(results, &elem(&1, 0))}
    end
  rescue
    error in [Ash.Error.Forbidden, Ash.Error.Invalid] -> {:error, error}
  end

  require Ash.Query

  # Four archive-store requests on the collision path (PUT, GET, HEAD,
  # final GET), each with three 60s receives and 500/1000ms retry delays:
  # 4 * (3 * 60_000 + 1_500) = 726_000ms. The hard store envelope adds
  # 24s for file hashing/local IO; it also bounds trickle responses/overrides.
  @store_budget_ms 750_000
  @io_budget_ms 60_000 + 120_000 + @store_budget_ms
  @metadata_budget_ms 5_000
  # 15s bounded lock acquisition + IO + metadata + 30s DB/cleanup reserve.
  @transaction_budget_ms 15_000 + @io_budget_ms + @metadata_budget_ms + 30_000

  @doc false
  def execution_budget do
    %{
      archive_store_ms: @store_budget_ms,
      io_ms: @io_budget_ms,
      metadata_ms: @metadata_budget_ms,
      transaction_ms: @transaction_budget_ms
    }
  end

  @doc false
  def execute(run_id, attempt) do
    case execute_transaction(run_id, attempt) do
      {:ok, {result, notifications}} ->
        Ash.Notifier.notify(notifications)
        result

      {:error, _} ->
        {:error, :recovery_unavailable}
    end
  rescue
    _ -> {:error, :recovery_unavailable}
  catch
    _, _ -> {:error, :recovery_unavailable}
  end

  defp execute_transaction(run_id, attempt) do
    Repo.transaction(
      fn ->
        Repo.query!("SET LOCAL lock_timeout = '15s'")

        run =
          Ingestion.ProcessingRun
          |> Ash.Query.filter(id == ^run_id)
          |> Ash.Query.lock(:for_update)
          |> Ash.read_one!()
          |> Ash.load!(source_version: [:source_record])

        if valid_generation?(run) do
          execute_valid(run, attempt)
        else
          {{:discard, "not an audited native-only recovery generation"}, []}
        end
      end,
      timeout: @transaction_budget_ms
    )
  end

  defp execute_valid(run, attempt) do
    case run.status do
      :succeeded ->
        replay_completed(run)

      :failed ->
        {:ok, []}

      :queued ->
        metadata =
          case bounded_io(fn -> metadata() end, @metadata_budget_ms) do
            %{} = value -> value
            _ -> Repo.rollback(:recovery_unavailable)
          end

        if {run.processor_name, run.processor_version, run.config_hash} ==
             {metadata.native_processor_name, metadata.native_processor_version,
              metadata.config_hash} do
          process(run, max(attempt, 1))
        else
          persist_failure(
            run,
            {:processor_provenance_mismatch, :native_extraction},
            max(attempt, 1)
          )
        end
    end
  end

  defp replay_completed(run) do
    artifacts = Ash.load!(run, :derived_artifacts).derived_artifacts

    with [artifact] <- Enum.filter(artifacts, &(&1.output_kind == "native-text")),
         true <-
           artifact.input_sha256 == run.source_version.sha256 and
             artifact.processor_name == run.processor_name and
             artifact.processor_version == run.processor_version and
             artifact.config_hash == run.config_hash and
             artifact.quality_measurements == run.quality_measurements,
         {:ok, _identity} <- verify_replay_file(artifact) do
      {:ok, []}
    else
      _ ->
        {_case, notifications} =
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
              summary:
                "Native-only recovery artifact failed replay verification; downstream remains held",
              diagnostics: %{"classification" => "corruption"},
              related_evidence: %{"processing_run_id" => run.id}
            },
            return_notifications?: true
          )

        {{:discard, "native-only recovery artifact failed verification"}, notifications}
    end
  end

  defp verify_replay_file(artifact) do
    workspace = Path.join(System.tmp_dir!(), "large-pdf-#{Ecto.UUID.generate()}")
    File.mkdir!(workspace)
    File.chmod!(workspace, 0o700)

    try do
      BrusselsWtf.Archive.fetch_file(
        artifact.object_key,
        artifact.output_sha256,
        artifact.byte_size,
        Path.join(workspace, "native.txt"),
        max_bytes: 67_108_864,
        timeout_ms: 60_000,
        receive_timeout_ms: 15_000
      )
    after
      File.rm_rf(workspace)
    end
  end

  defp valid_generation?(run) do
    with true <- run.inputs["extraction_only"] == true,
         true <- run.inputs["operation"] == "extract_large_native",
         audit_id when is_binary(audit_id) <- run.inputs["review_action_id"],
         %{} = audit <- Ash.get!(Review.Action, audit_id, authorize?: false, error?: false),
         %{} = review_case <-
           Ash.get!(Review.Case, run.inputs["review_case_id"], authorize?: false, error?: false) do
      run.generation_key == "review:#{audit.id}" and
        run.processor_role == :native_extraction and audit.action == :retry and
        audit.effect == :processing_generation and audit.review_case_id == review_case.id and
        audit.details["operation"] == "extract_large_native" and
        audit.details["extraction_only"] == true and
        audit.details["source_version_id"] == run.source_version_id and
        audit.details["sha256"] == run.source_version.sha256 and
        run.inputs["source_sha256"] == run.source_version.sha256 and
        audit.details["processor_name"] == run.processor_name and
        audit.details["processor_version"] == run.processor_version and
        audit.details["config_hash"] == run.config_hash and
        eligible?(%{review_case | status: :open}, run.source_version)
    else
      _ -> false
    end
  end

  defp process(run, attempt) do
    started = System.monotonic_time(:millisecond)
    workspace = Path.join(System.tmp_dir!(), "large-pdf-#{Ecto.UUID.generate()}")
    File.mkdir!(workspace)
    File.chmod!(workspace, 0o700)
    version = run.source_version
    input = Path.join(workspace, "source.pdf")

    result =
      try do
        bounded_io(
          fn ->
            with {:ok, _identity} <-
                   BrusselsWtf.Archive.fetch_file(
                     version.object_key,
                     version.sha256,
                     version.byte_size,
                     input,
                     max_bytes: Ingestion.SourceLimits.supporting_document_limit(),
                     timeout_ms: 60_000,
                     receive_timeout_ms: 15_000
                   ),
                 {:ok, extracted} <-
                   processor().native(
                     %{
                       sha256: version.sha256,
                       media_type: version.media_type,
                       byte_size: version.byte_size
                     },
                     input,
                     workspace,
                     []
                   ),
                 :ok <- validate_result(extracted, workspace),
                 {:ok, archived} <-
                   bounded_io(
                     fn -> BrusselsWtf.Archive.store_file(extracted.text_path, :derived) end,
                     @store_budget_ms,
                     false
                   ) do
              {:ok, extracted, archived}
            else
              {:error, reason} -> {:error, reason}
            end
          end,
          @io_budget_ms
        )
      after
        File.rm_rf(workspace)
      end

    case result do
      {:ok, extracted, archived} ->
        {:ok, persist_result(run, extracted, archived, attempt)}

      {:error, reason} ->
        persist_failure(run, reason, attempt, System.monotonic_time(:millisecond) - started)
    end
  end

  # Only non-DB work runs in the linked child. The lock owner checks the
  # checked-out connection while waiting and again before accepting any result.
  # Do not log exception structs: Ash/transport failures can include private data.
  defp bounded_io(fun, timeout, heartbeat? \\ true) do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          _ -> {:error, {:processor_failed, :native_file}}
        catch
          _, _ -> {:error, {:processor_failed, :native_file}}
        end
      end)

    try do
      await_io(task, System.monotonic_time(:millisecond) + timeout, heartbeat?)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp await_io(task, deadline, heartbeat?) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :archive_timeout}
    else
      case Task.yield(task, min(remaining, 1_000)) do
        {:ok, result} ->
          if heartbeat?, do: Repo.query!("SELECT 1", [], timeout: 1_000)
          result

        {:exit, _} ->
          {:error, {:processor_failed, :native_file}}

        nil ->
          if heartbeat?, do: Repo.query!("SELECT 1", [], timeout: 1_000)
          await_io(task, deadline, heartbeat?)
      end
    end
  end

  defp validate_result(result, workspace) do
    quality = result.quality_measurements
    pages = quality["pages"]
    count = result.page_count

    with true <- is_integer(count) and count in 1..500 and quality["page_count"] == count,
         true <- is_list(pages) and length(pages) == count,
         true <- Enum.map(pages, & &1["page"]) == Enum.to_list(1..count),
         true <- Enum.all?(pages, &(&1["decision"] in ["accepted", "ocr_required"])),
         true <- quality["accepted"] == Enum.all?(pages, &(&1["decision"] == "accepted")),
         true <-
           quality["rejected_pages"] ==
             Enum.filter(pages, &(&1["decision"] != "accepted")) |> Enum.map(& &1["page"]),
         true <- String.starts_with?(Path.expand(result.text_path), Path.expand(workspace) <> "/"),
         {:ok, %{type: :regular, size: size}} <- File.lstat(result.text_path),
         true <- size == result.text_byte_size and size <= 67_108_864 do
      :ok
    else
      _ -> {:error, {:invalid_content, :native_result_contract}}
    end
  end

  defp classify_failure({:hash_mismatch, _, _}), do: :corruption
  defp classify_failure({:size_mismatch, _, _}), do: :corruption
  defp classify_failure(reason), do: Ingestion.ProcessingFailure.classify(reason)

  defp persist_failure(run, reason, attempt, duration_ms \\ 0) do
    classification = classify_failure(reason)
    terminal? = Ingestion.ProcessingFailure.deterministic?(classification) or attempt >= 3

    classification =
      if terminal?, do: Ingestion.ProcessingFailure.terminal(classification), else: classification

    now = BrusselsWtf.Clock.utc_now()

    {_attempt, attempt_notifications} =
      Ingestion.record_processing_attempt!(
        %{
          processing_run_id: run.id,
          attempt: attempt,
          status: :failed,
          failure_classification: Atom.to_string(classification),
          started_at: DateTime.add(now, -duration_ms, :millisecond),
          completed_at: now,
          duration_ms: duration_ms,
          tool_versions: run.tool_versions,
          diagnostics: %{"classification" => Atom.to_string(classification)}
        },
        return_notifications?: true
      )

    if terminal? do
      {_run, run_notifications} =
        Ingestion.complete_processing_run!(
          run,
          %{
            status: :failed,
            failure_classification: Atom.to_string(classification),
            started_at: DateTime.add(now, -duration_ms, :millisecond),
            completed_at: now,
            duration_ms: duration_ms,
            diagnostics: %{"classification" => Atom.to_string(classification)}
          },
          return_notifications?: true
        )

      {_case, case_notifications} =
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
            summary: "Native-only large PDF recovery failed; downstream remains held",
            diagnostics: %{"classification" => Atom.to_string(classification)},
            related_evidence: %{"processing_run_id" => run.id}
          },
          return_notifications?: true
        )

      {:ok, attempt_notifications ++ run_notifications ++ case_notifications}
    else
      {{:error, :processing_failed}, attempt_notifications}
    end
  end

  defp persist_result(run, result, archived, attempt) do
    version = run.source_version
    completed_at = BrusselsWtf.Clock.utc_now()
    started_at = DateTime.add(completed_at, -result.duration_ms, :millisecond)

    {completed, run_notifications} =
      Ingestion.complete_processing_run!(
        run,
        %{
          status: :succeeded,
          output: %{
            "source_sha256" => version.sha256,
            "page_count" => result.page_count,
            "text_byte_size" => archived.byte_size
          },
          quality_measurements: result.quality_measurements,
          diagnostics: result.diagnostics,
          tool_versions: result.tool_versions,
          started_at: started_at,
          completed_at: completed_at,
          duration_ms: result.duration_ms
        },
        return_notifications?: true
      )

    {_attempt, attempt_notifications} =
      Ingestion.record_processing_attempt!(
        %{
          processing_run_id: completed.id,
          attempt: attempt,
          status: :succeeded,
          quality_measurements: result.quality_measurements,
          diagnostics: result.diagnostics,
          tool_versions: result.tool_versions,
          started_at: started_at,
          completed_at: completed_at,
          duration_ms: result.duration_ms
        },
        return_notifications?: true
      )

    {artifact, artifact_notifications} =
      Ingestion.upsert_derived_artifact!(
        %{
          source_version_id: version.id,
          processing_run_id: completed.id,
          input_sha256: version.sha256,
          output_sha256: archived.sha256,
          object_key: archived.object_key,
          byte_size: archived.byte_size,
          processor_name: completed.processor_name,
          processor_version: completed.processor_version,
          config_hash: completed.config_hash,
          output_kind: "native-text",
          media_type: "text/plain; charset=utf-8",
          schema_version: "derived-artifact-v1",
          quality_measurements: result.quality_measurements
        },
        return_notifications?: true
      )

    {_link, link_notifications} =
      Ingestion.link_processing_run_artifact!(
        %{
          processing_run_id: completed.id,
          derived_artifact_id: artifact.id,
          role: :native_output
        },
        return_notifications?: true
      )

    case_notifications =
      if result.quality_measurements["accepted"] do
        {_case, notifications} =
          Review.complete_retry_with_notifications!(run.inputs["review_case_id"])

        notifications
      else
        []
      end

    run_notifications ++
      attempt_notifications ++ artifact_notifications ++ link_notifications ++ case_notifications
  end

  def eligible?(review_case, version) do
    version = Ash.load!(version, :source_record)

    review_case.kind == :extraction and review_case.status == :open and
      review_case.disposition != :unsupported and
      review_case.processing_generation == "large-source-acquisition-v1" and
      review_case.affected_record_type == "source_version" and
      review_case.affected_record_id == version.id and review_case.source_version_id == version.id and
      review_case.source_record_id == version.source_record_id and
      version.source_record.role == :supporting_document and
      version.media_type == "application/pdf" and
      version.byte_size > 0 and version.byte_size > Ingestion.SourceLimits.processing_limit() and
      version.byte_size <= Ingestion.SourceLimits.supporting_document_limit()
  end

  defp validate_options(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) == [:actor],
      do: :ok,
      else: {:error, :invalid_request_options}
  end

  defp validate_manifest(entries) when is_list(entries) and length(entries) in 1..5 do
    valid =
      Enum.all?(entries, fn entry ->
        is_map(entry) and Enum.sort(Map.keys(entry)) == [:case_id, :sha256, :source_version_id] and
          match?({:ok, _}, Ecto.UUID.cast(entry.case_id)) and
          match?({:ok, _}, Ecto.UUID.cast(entry.source_version_id)) and
          is_binary(entry.sha256) and Regex.match?(~r/\A[0-9a-f]{64}\z/, entry.sha256)
      end)

    if valid and length(Enum.uniq_by(entries, &Ecto.UUID.cast(&1.case_id))) == length(entries) and
         length(Enum.uniq_by(entries, &Ecto.UUID.cast(&1.source_version_id))) == length(entries),
       do: :ok,
       else: {:error, :invalid_manifest}
  end

  defp validate_manifest(_entries), do: {:error, :invalid_manifest}
end
