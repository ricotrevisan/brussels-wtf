defmodule BrusselsWtf.Ingestion.Pipeline do
  @moduledoc """
  Commune ingestion boundary invoked by Oban workers.

  External I/O remains behind controllable HTTP, archive, and processor
  adapters; all durable transitions use named Ash actions.
  """

  alias BrusselsWtf.Council
  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Workers

  @listing_roles [:document_listing, :item_listing]
  @processable_roles [
    :agenda,
    :complementary_agenda,
    :project,
    :explanatory_note,
    :complementary_explanatory_note,
    :explanatory_notes,
    :supplement,
    :addendum,
    :minutes,
    :register,
    :motion,
    :question,
    :interpellation,
    :supporting_document,
    :mandate_declaration
  ]

  @spec discover_and_enqueue(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          pos_integer()
        ) :: :ok | :disappeared | {:retry, pos_integer()} | {:review, atom()}
  def discover_and_enqueue(commune_id, poll_run_id, check_key, attempt \\ 1) do
    commune = Ingestion.get_commune!(commune_id)
    poll_run = Ingestion.get_poll_run!(poll_run_id)
    commune = %{commune | index_url: BrusselsWtf.Communes.poll_index_url(commune, poll_run.scope)}
    now = BrusselsWtf.Clock.utc_now()

    index_locator =
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: commune.index_url,
        parent_index_url: commune.index_url,
        meeting_identifier: "index",
        role: :index,
        language: :fr,
        observed_label: "Authoritative council index",
        discovered_at: now
      })

    newly_discovered? = newly_discovered?(index_locator.id)

    case BrusselsWtf.HTTP.get(commune.index_url, conditional_options(index_locator)) do
      {:ok, %{status: 304} = response} ->
        case current_version(index_locator) do
          nil ->
            record_observation(index_locator, poll_run.id, response, check_key,
              status: :failure,
              error_kind: "not_modified_without_version",
              error_message: "HTTP 304 was observed before any archived index version"
            )

            {:review, :invalid_content}

          version ->
            record_observation(index_locator, poll_run.id, response, check_key,
              status: :unchanged,
              sha256: version.sha256,
              source_version_id: version.id
            )

            enqueue_document_fetches(commune.id, poll_run, check_key)
            :ok
        end

      {:ok, %{status: status, body: body} = response} when status in 200..299 ->
        case archive_index(index_locator, response, body, now) do
          {:ok, version, observation_status} ->
            if observation_status == :success do
              BrusselsWtf.Ingestion.Observability.archive_stored(
                poll_run.id,
                index_locator.id,
                version.id,
                byte_size(body)
              )
            end

            case discover(commune, body) do
              {:ok, discovered} ->
                record_observation(index_locator, poll_run.id, response, check_key,
                  status: observation_status,
                  sha256: version.sha256,
                  source_version_id: version.id
                )

                known_urls =
                  commune.id
                  |> Ingestion.list_locators!()
                  |> MapSet.new(& &1.url)

                stored =
                  Enum.map(discovered, fn locator ->
                    new_locator? = not MapSet.member?(known_urls, locator.url)

                    Ingestion.upsert_locator!(%{
                      commune_id: commune.id,
                      url: locator.url,
                      parent_index_url: locator.parent_index_url,
                      meeting_identifier: locator.meeting_identifier,
                      scheduled_on: locator.scheduled_on,
                      role: locator.role,
                      language: locator.language,
                      observed_label: locator.observed_label,
                      item_identifier: locator.item_identifier,
                      dossier_identifier: Map.get(locator, :dossier_identifier),
                      discovered_at: now,
                      next_fetch_at:
                        initial_next_fetch_at(
                          locator,
                          now,
                          poll_run.kind,
                          poll_run.scope,
                          new_locator?
                        )
                    })
                  end)

                stored =
                  Enum.map(
                    stored,
                    &reactivate_if_rediscovered(&1, now, poll_run.kind, poll_run.scope)
                  )

                mark_disappeared(
                  commune.id,
                  poll_run.id,
                  check_key,
                  stored,
                  now,
                  poll_run.scope
                )

                fetchable = scope_discovered(stored, poll_run.scope, now)
                enqueue_document_fetches(commune.id, poll_run, check_key, fetchable)
                :ok

              {:error, reason} ->
                record_observation(index_locator, poll_run.id, response, check_key,
                  status: :failure,
                  sha256: version.sha256,
                  source_version_id: version.id,
                  error_kind: "parser_failure",
                  error_message: safe_error(reason)
                )

                {:review, :parser_ambiguity}
            end

          {:error, reason} ->
            record_observation(index_locator, poll_run.id, response, check_key,
              status: :failure,
              error_kind: "corruption",
              error_message: safe_error(reason)
            )

            {:review, :corruption}
        end

      {:ok, response} ->
        decision =
          BrusselsWtf.Ingestion.RetryPolicy.decision(
            {:http, response.status, Map.get(response, :headers, %{})},
            attempt,
            now: now,
            newly_discovered?: newly_discovered?,
            jitter_key: check_key
          )

        record_observation(index_locator, poll_run.id, response, check_key,
          status: if(decision == :disappeared, do: :disappeared, else: :failure),
          error_kind: http_error_kind(response.status, decision),
          error_message: "authoritative index returned HTTP #{response.status}"
        )

        decision

      {:error, failure} ->
        record_transport_failure(index_locator, poll_run.id, check_key, failure, now)

        BrusselsWtf.Ingestion.RetryPolicy.decision(
          {:transport, failure.reason},
          attempt,
          now: now,
          newly_discovered?: newly_discovered?,
          jitter_key: check_key
        )
    end
  end

  @spec retrieve(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), pos_integer()) ::
          :ok | :disappeared | {:retry, pos_integer()} | {:review, atom()}
  def retrieve(locator_id, poll_run_id, check_key, attempt \\ 1) do
    locator = Ingestion.get_locator!(locator_id)
    now = BrusselsWtf.Clock.utc_now()
    newly_discovered? = newly_discovered?(locator.id)

    result =
      with_source_response(locator, fn result ->
        case result do
          {:ok, %{status: 304} = response} ->
            case current_version(locator) do
              nil ->
                record_observation(locator, poll_run_id, response, check_key,
                  status: :failure,
                  error_kind: "not_modified_without_version",
                  error_message: "HTTP 304 was observed before any archived source version"
                )

                {:review, :invalid_content}

              version ->
                record_observation(locator, poll_run_id, response, check_key,
                  status: :unchanged,
                  sha256: version.sha256,
                  source_version_id: version.id
                )

                if locator.role in @listing_roles do
                  enqueue_known_children(locator, poll_run_id, check_key)
                end

                :ok
            end

          {:ok, %{status: status, file_path: path} = response} when status in 200..299 ->
            archive_file_success(locator, poll_run_id, check_key, response, path, now)

          {:ok, %{status: status, body: body} = response} when status in 200..299 ->
            archive_success(locator, poll_run_id, check_key, response, body, now)

          {:ok, response} ->
            decision =
              BrusselsWtf.Ingestion.RetryPolicy.decision(
                {:http, response.status, Map.get(response, :headers, %{})},
                attempt,
                now: now,
                newly_discovered?: newly_discovered?,
                jitter_key: check_key
              )

            record_observation(locator, poll_run_id, response, check_key,
              status: if(decision == :disappeared, do: :disappeared, else: :failure),
              error_kind: http_error_kind(response.status, decision),
              error_message: "source locator returned HTTP #{response.status}"
            )

            decision

          {:error, failure} ->
            record_transport_failure(locator, poll_run_id, check_key, failure, now)

            BrusselsWtf.Ingestion.RetryPolicy.decision(
              {:transport, failure.reason},
              attempt,
              now: now,
              newly_discovered?: newly_discovered?,
              jitter_key: check_key
            )
        end
      end)

    checked_attrs = %{last_checked_at: now}

    checked_attrs =
      if result == :ok and changed_observation?(locator.id, check_key),
        do: Map.put(checked_attrs, :last_changed_at, now),
        else: checked_attrs

    Ingestion.schedule_locator_fetch!(locator, checked_attrs)
    result
  end

  defp with_source_response(%{role: :supporting_document} = locator, callback) do
    directory = Path.join(System.tmp_dir!(), "brussels-source-#{Ecto.UUID.generate()}")
    path = Path.join(directory, "source")

    case File.mkdir(directory) do
      :ok ->
        try do
          with :ok <- File.chmod(directory, 0o700) do
            options =
              Keyword.put(
                conditional_options(locator),
                :max_body_bytes,
                Ingestion.SourceLimits.supporting_document_limit()
              )

            result =
              case BrusselsWtf.HTTP.download(locator.url, path, options) do
                {:ok, response} -> {:ok, Map.put(response, :file_path, path)}
                failure -> failure
              end

            callback.(result)
          else
            {:error, reason} -> callback.(temporary_file_failure(locator, reason))
          end
        after
          File.rm_rf!(directory)
        end

      {:error, reason} ->
        callback.(temporary_file_failure(locator, reason))
    end
  end

  defp with_source_response(locator, callback) do
    callback.(BrusselsWtf.HTTP.get(locator.url, conditional_options(locator)))
  end

  defp temporary_file_failure(locator, reason) do
    {:error,
     %{
       reason: {:file_write, reason},
       final_url: locator.url,
       response_headers: %{},
       redirect_chain: []
     }}
  end

  @spec extract(Ecto.UUID.t()) :: :ok | {:error, term()}
  def extract(source_version_id, attempt \\ 1, generation_kind \\ :automatic) do
    version = Ash.load!(Ingestion.get_source_version!(source_version_id), :source_record)
    run = prepare_native_generation(version, generation_kind)

    case run.status do
      :succeeded -> reconcile_native_success(version, run)
      :failed -> reconcile_failed_review(run)
      :queued -> run_native_attempt(version, run, attempt)
    end
  end

  defp run_native_attempt(version, run, attempt) do
    attempt_started_at = BrusselsWtf.Clock.utc_now()
    attempt_started_monotonic = System.monotonic_time()

    result =
      with :ok <- Ingestion.SourceLimits.check_processing(version),
           {:ok, bytes} <- BrusselsWtf.Archive.get(version.object_key),
           actual when actual == version.sha256 <- BrusselsWtf.Digest.sha256(bytes),
           {:ok, extracted} <-
             BrusselsWtf.PDF.Processor.native(
               %{sha256: version.sha256, media_type: version.media_type},
               bytes
             ),
           extracted = declaration_result(version, extracted, :native),
           {:ok, archived_text} <- BrusselsWtf.Archive.store(extracted.text, :derived) do
        record_native_result(version, run, extracted, archived_text, attempt)
      else
        actual when is_binary(actual) ->
          {:error, {:archived_hash_mismatch, version.sha256, actual}}

        {:error, reason} ->
          {:error, reason}
      end

    case result do
      :ok ->
        :ok

      {:error, reason} = error ->
        record_failed_attempt(
          run,
          attempt,
          reason,
          attempt_started_at,
          elapsed_milliseconds(attempt_started_monotonic)
        )

        error
    end
  end

  defp pdf_meta(version) do
    meta = %{sha256: version.sha256, media_type: version.media_type}

    if version.source_record.role == :mandate_declaration,
      do: Map.put(meta, :ocr_profile, :scanned_declaration),
      else: meta
  end

  defp declaration_result(
         %{source_record: %{role: :mandate_declaration}} = version,
         result,
         stage
       ) do
    text = BrusselsWtf.Identity.MandateDeclaration.safe_text(version.sha256, result.text)

    quality =
      BrusselsWtf.Identity.MandateDeclaration.quality(
        version.sha256,
        result.quality_measurements,
        stage
      )

    result
    |> Map.put(:text, text)
    |> Map.put(:quality_measurements, quality)
    |> Map.put(:output, %{"text" => text, "page_count" => result.page_count})
  end

  defp declaration_result(_version, result, _stage), do: result

  defp prepare_native_generation(version, generation_kind) do
    metadata = BrusselsWtf.PDF.Processor.metadata()

    Ingestion.record_processing_run!(%{
      source_version_id: version.id,
      processor_role: :native_extraction,
      inputs: %{
        "source_sha256" => version.sha256,
        "generation_kind" => generation_kind(generation_kind)
      },
      processor_name: metadata.native_processor_name,
      processor_version: metadata.native_processor_version,
      config_hash: metadata.config_hash,
      status: :queued,
      output: %{}
    })
  end

  defp record_native_result(version, run, result, archived_text, attempt) do
    {run, native_artifact} =
      persist_native_success(
        version,
        run,
        result,
        archived_text,
        attempt,
        extraction_summary(result, version.sha256)
      )

    emit_extraction_completed(run, version.id, result)

    if result.quality_measurements["accepted"] do
      enqueue_normalization(run, version.source_record.origin_url)
    else
      enqueue_ocr(version, run, native_artifact, result.quality_measurements)
    end
  end

  defp persist_native_success(version, run, result, archived_text, attempt, output) do
    completed_at = BrusselsWtf.Clock.utc_now()
    started_at = DateTime.add(completed_at, -result.duration_ms, :millisecond)

    {:ok, {completed, artifact, notifications}} =
      BrusselsWtf.Repo.transaction(fn ->
        {completed, run_notifications} =
          Ingestion.complete_processing_run!(
            run,
            %{
              status: :succeeded,
              output: output,
              tool_versions: result.tool_versions,
              diagnostics: result.diagnostics,
              quality_measurements: result.quality_measurements,
              started_at: started_at,
              completed_at: completed_at,
              duration_ms: result.duration_ms
            },
            return_notifications?: true
          )

        attempt_notifications =
          record_succeeded_attempt(completed, attempt, result, started_at, completed_at)

        {artifact, artifact_notifications} =
          Ingestion.upsert_derived_artifact!(
            %{
              source_version_id: version.id,
              processing_run_id: completed.id,
              input_sha256: version.sha256,
              output_sha256: archived_text.sha256,
              processor_name: completed.processor_name,
              processor_version: completed.processor_version,
              config_hash: completed.config_hash,
              output_kind: "native-text",
              object_key: archived_text.object_key,
              media_type: "text/plain; charset=utf-8",
              byte_size: byte_size(result.text),
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

        review_notifications =
          if result.quality_measurements["accepted"] and output["review_case_id"] do
            {_case, notifications} =
              BrusselsWtf.Review.complete_retry_with_notifications!(output["review_case_id"])

            notifications
          else
            []
          end

        if result.quality_measurements["accepted"] do
          BrusselsWtf.Identity.IxellesPublicMandateProcessor.enqueue_waiting_for_source_version!(
            version.id
          )
        end

        notifications =
          run_notifications ++
            attempt_notifications ++
            artifact_notifications ++ link_notifications ++ review_notifications

        {completed, artifact, notifications}
      end)

    Ash.Notifier.notify(notifications)
    {completed, artifact}
  end

  defp emit_extraction_completed(run, source_version_id, result) do
    Ingestion.Observability.extraction_completed(
      %{
        source_version_id: source_version_id,
        processing_run_id: run.id,
        processor_role: run.processor_role,
        status: :succeeded
      },
      result.duration_ms,
      result.quality_measurements["rejected_pages"]
    )
  end

  defp reconcile_failed_review(run) do
    run = Ash.load!(run, :source_version)

    BrusselsWtf.Ingestion.ExtractionReview.open_for_version(
      run.source_version.id,
      BrusselsWtf.Ingestion.ProcessingFailure.from_persisted(run.failure_classification),
      run.id
    )

    :ok
  end

  defp reconcile_native_success(version, run) do
    run = Ash.load!(run, :derived_artifacts)
    artifact = Enum.find(run.derived_artifacts, &(&1.output_kind == "native-text"))

    if run.quality_measurements["accepted"] do
      BrusselsWtf.Identity.IxellesPublicMandateProcessor.enqueue_waiting_for_source_version!(
        version.id
      )

      if review_case_id = run.output["review_case_id"] do
        BrusselsWtf.Review.complete_retry!(review_case_id)
      end

      enqueue_normalization(run, version.source_record.origin_url)
    else
      enqueue_ocr(version, run, artifact, run.quality_measurements)
    end
  end

  defp reconcile_ocr_success(run) do
    if review_case_id = run.inputs["review_case_id"] do
      BrusselsWtf.Review.complete_retry!(review_case_id)
    end

    enqueue_normalization(run, run.source_version.source_record.origin_url)
  end

  defp verify_processor_provenance(run, role) do
    metadata =
      if role == :ocr and run.inputs["ocr_profile"] == "scanned_declaration",
        do: BrusselsWtf.PDF.Processor.metadata(%{ocr_profile: :scanned_declaration}),
        else: BrusselsWtf.PDF.Processor.metadata()

    expected =
      case role do
        :native_extraction ->
          {metadata.native_processor_name, metadata.native_processor_version,
           metadata.config_hash}

        :ocr ->
          {metadata.ocr_processor_name, metadata.ocr_processor_version, metadata.config_hash}
      end

    actual = {run.processor_name, run.processor_version, run.config_hash}

    if actual == expected,
      do: :ok,
      else: {:error, {:processor_provenance_mismatch, role}}
  end

  defp enqueue_ocr(
         %{source_record: %{role: :mandate_declaration}} = version,
         _native_run,
         _native_artifact,
         %{"rejected_pages" => []}
       ) do
    BrusselsWtf.Identity.IxellesMandateDeclarationProcessor.review_document(
      version,
      :uninspected_source_version
    )
  end

  defp enqueue_ocr(version, native_run, native_artifact, quality) do
    metadata = BrusselsWtf.PDF.Processor.metadata(pdf_meta(version))
    limits = Application.fetch_env!(:brussels_wtf, :pdf_limits)

    run =
      Ingestion.record_processing_run!(%{
        source_version_id: version.id,
        processor_role: :ocr,
        generation_key: "ocr:#{native_run.id}",
        inputs: %{
          "source_sha256" => version.sha256,
          "native_run_id" => native_run.id,
          "native_artifact_id" => native_artifact.id,
          "review_case_id" => native_run.output["review_case_id"],
          "generation_kind" => native_run.inputs["generation_kind"] || "automatic",
          "pages" => quality["rejected_pages"],
          "ocr_profile" =>
            if(version.source_record.role == :mandate_declaration,
              do: "scanned_declaration",
              else: "default"
            ),
          "languages" => limits.ocr_languages,
          "limits" => Map.new(limits, fn {key, value} -> {to_string(key), value} end)
        },
        processor_name: metadata.ocr_processor_name,
        processor_version: metadata.ocr_processor_version,
        config_hash: metadata.config_hash,
        status: :queued,
        output: %{}
      })

    Ingestion.Observability.ocr_routed(
      %{source_version_id: version.id, processing_run_id: run.id, processor_role: :ocr},
      length(quality["rejected_pages"])
    )

    %{processing_run_id: run.id}
    |> Workers.OCRSource.new()
    |> Oban.insert!()

    :ok
  end

  defp enqueue_normalization(run, locator_url) do
    version = Ingestion.get_source_version!(run.source_version_id) |> Ash.load!(:source_record)

    if version.source_record.role == :mandate_declaration do
      BrusselsWtf.Identity.IxellesMandateDeclarationProcessor.enqueue_waiting_for_source_version!(
        version.id
      )
    else
      enqueue_council_normalization(run, locator_url)
    end
  end

  defp enqueue_council_normalization(run, locator_url) do
    %{
      processing_run_id: run.id,
      locator_url: locator_url,
      processor_contract: BrusselsWtf.Processors.normalization_contract(),
      generation_kind: run.inputs["generation_kind"] || "automatic"
    }
    |> Workers.NormalizeSource.new()
    |> Oban.insert!()

    :ok
  end

  @spec ocr(Ecto.UUID.t(), pos_integer()) :: :ok | {:error, term()}
  def ocr(processing_run_id, attempt \\ 1) do
    run =
      Ash.load!(Ingestion.get_processing_run!(processing_run_id),
        source_version: [:source_record]
      )

    case run.status do
      :succeeded -> reconcile_ocr_success(run)
      :failed -> reconcile_failed_review(run)
      :queued -> run_ocr_attempt(run, attempt)
    end
  end

  defp run_ocr_attempt(run, attempt) do
    attempt_started_at = BrusselsWtf.Clock.utc_now()
    attempt_started_monotonic = System.monotonic_time()
    version = run.source_version
    pages = run.inputs["pages"]

    result =
      with :ok <- verify_processor_provenance(run, :ocr),
           :ok <- Ingestion.SourceLimits.check_processing(version),
           {:ok, bytes} <- BrusselsWtf.Archive.get(version.object_key),
           actual when actual == version.sha256 <- BrusselsWtf.Digest.sha256(bytes),
           {:ok, extracted} <-
             BrusselsWtf.PDF.Processor.ocr(
               pdf_meta(version),
               bytes,
               pages
             ),
           extracted = declaration_result(version, extracted, :ocr),
           {:ok, archived_pdf} <- BrusselsWtf.Archive.store(extracted.searchable_pdf, :derived),
           {:ok, archived_text} <- BrusselsWtf.Archive.store(extracted.text, :derived) do
        case ensure_accepted_quality(extracted.quality_measurements) do
          :ok ->
            complete_ocr(run, extracted, archived_pdf, archived_text, attempt)

          {:error, _reason} = error ->
            persist_rejected_ocr_artifacts(run, extracted, archived_pdf, archived_text)
            error
        end
      else
        false ->
          {:error, {:quality_failure, %{stage: :ocr}}}

        actual when is_binary(actual) ->
          {:error, {:archived_hash_mismatch, version.sha256, actual}}

        {:error, reason} ->
          {:error, reason}
      end

    case result do
      :ok ->
        :ok

      {:error, reason} = error ->
        record_failed_attempt(
          run,
          attempt,
          reason,
          attempt_started_at,
          elapsed_milliseconds(attempt_started_monotonic)
        )

        error
    end
  end

  defp persist_rejected_ocr_artifacts(run, result, archived_pdf, archived_text) do
    {:ok, notifications} =
      BrusselsWtf.Repo.transaction(fn ->
        persist_ocr_artifacts(run, result, archived_pdf, archived_text)
      end)

    Ash.Notifier.notify(notifications)
    :ok
  end

  defp persist_ocr_artifacts(run, result, archived_pdf, archived_text) do
    Enum.flat_map(
      [
        {"ocr-pdf", archived_pdf, "application/pdf"},
        {"ocr-text", archived_text, "text/plain; charset=utf-8"}
      ],
      fn {kind, archived, media_type} ->
        {artifact, created_notifications} =
          Ingestion.upsert_derived_artifact!(
            %{
              source_version_id: run.source_version.id,
              processing_run_id: run.id,
              input_sha256: run.source_version.sha256,
              output_sha256: archived.sha256,
              processor_name: run.processor_name,
              processor_version: run.processor_version,
              config_hash: run.config_hash,
              output_kind: kind,
              object_key: archived.object_key,
              media_type: media_type,
              byte_size:
                if(kind == "ocr-pdf",
                  do: byte_size(result.searchable_pdf),
                  else: byte_size(result.text)
                ),
              schema_version: "derived-artifact-v1",
              quality_measurements: result.quality_measurements
            },
            return_notifications?: true
          )

        {_link, linked_notifications} =
          Ingestion.link_processing_run_artifact!(
            %{
              processing_run_id: run.id,
              derived_artifact_id: artifact.id,
              role: if(kind == "ocr-pdf", do: :ocr_document, else: :ocr_output)
            },
            return_notifications?: true
          )

        created_notifications ++ linked_notifications
      end
    )
  end

  defp complete_ocr(run, result, archived_pdf, archived_text, attempt) do
    completed_at = BrusselsWtf.Clock.utc_now()
    started_at = DateTime.add(completed_at, -result.duration_ms, :millisecond)

    {:ok, {completed, notifications}} =
      BrusselsWtf.Repo.transaction(fn ->
        {completed, run_notifications} =
          Ingestion.complete_processing_run!(
            run,
            %{
              status: :succeeded,
              output: extraction_summary(result, run.source_version.sha256),
              tool_versions: result.tool_versions,
              diagnostics: result.diagnostics,
              quality_measurements: result.quality_measurements,
              started_at: started_at,
              completed_at: completed_at,
              duration_ms: result.duration_ms
            },
            return_notifications?: true
          )

        attempt_notifications =
          record_succeeded_attempt(completed, attempt, result, started_at, completed_at)

        artifact_notifications =
          persist_ocr_artifacts(completed, result, archived_pdf, archived_text)

        review_notifications =
          if review_case_id = completed.inputs["review_case_id"] do
            {_case, notifications} =
              BrusselsWtf.Review.complete_retry_with_notifications!(review_case_id)

            notifications
          else
            []
          end

        notifications =
          run_notifications ++
            attempt_notifications ++ artifact_notifications ++ review_notifications

        {completed, notifications}
      end)

    Ash.Notifier.notify(notifications)
    emit_extraction_completed(completed, run.source_version.id, result)
    enqueue_normalization(completed, run.source_version.source_record.origin_url)
  end

  @spec retry_extraction(Ecto.UUID.t()) :: :ok | {:error, term()}
  def retry_extraction(processing_run_id, attempt \\ 1) do
    run =
      Ash.load!(Ingestion.get_processing_run!(processing_run_id),
        source_version: [:source_record]
      )

    case run.status do
      :succeeded -> reconcile_native_success(run.source_version, run)
      :failed -> reconcile_failed_review(run)
      :queued -> run_review_retry_attempt(run, attempt)
    end
  end

  defp run_review_retry_attempt(run, attempt) do
    attempt_started_at = BrusselsWtf.Clock.utc_now()
    attempt_started_monotonic = System.monotonic_time()
    version = run.source_version

    result =
      with :ok <- verify_processor_provenance(run, :native_extraction),
           :ok <- Ingestion.SourceLimits.check_processing(version),
           {:ok, bytes} <- BrusselsWtf.Archive.get(version.object_key),
           actual when actual == version.sha256 <- BrusselsWtf.Digest.sha256(bytes),
           {:ok, extracted} <-
             BrusselsWtf.PDF.Processor.native(
               %{sha256: version.sha256, media_type: version.media_type},
               bytes
             ),
           extracted = declaration_result(version, extracted, :native),
           {:ok, archived_text} <- BrusselsWtf.Archive.store(extracted.text, :derived) do
        complete_review_extraction(run, extracted, archived_text, attempt)
      else
        actual when is_binary(actual) ->
          {:error, {:archived_hash_mismatch, version.sha256, actual}}

        {:error, reason} ->
          {:error, reason}
      end

    case result do
      :ok ->
        :ok

      {:error, reason} = error ->
        record_failed_attempt(
          run,
          attempt,
          reason,
          attempt_started_at,
          elapsed_milliseconds(attempt_started_monotonic)
        )

        error
    end
  end

  defp complete_review_extraction(run, result, archived_text, attempt) do
    output =
      extraction_summary(result, run.source_version.sha256)
      |> Map.merge(Map.take(run.output || %{}, ["review_action_id", "review_case_id", "note"]))

    {completed, artifact} =
      persist_native_success(run.source_version, run, result, archived_text, attempt, output)

    emit_extraction_completed(completed, run.source_version.id, result)

    if result.quality_measurements["accepted"] do
      enqueue_normalization(completed, run.source_version.source_record.origin_url)
    else
      enqueue_ocr(run.source_version, completed, artifact, result.quality_measurements)
    end
  end

  @spec normalize(Ecto.UUID.t(), String.t()) :: :ok | {:error, term()}
  def normalize(processing_run_id, citation_url),
    do: normalize(processing_run_id, citation_url, 1, 3, :automatic)

  @spec normalize(Ecto.UUID.t(), String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, term()}
  def normalize(processing_run_id, citation_url, attempt, max_attempts),
    do: normalize(processing_run_id, citation_url, attempt, max_attempts, :automatic)

  @spec normalize(Ecto.UUID.t(), String.t(), pos_integer(), pos_integer(), atom()) ::
          :ok | {:error, term()}
  def normalize(processing_run_id, citation_url, attempt, max_attempts, generation_kind) do
    run =
      Ash.load!(Ingestion.get_processing_run!(processing_run_id),
        source_version: [source_record: [:commune]]
      )

    version = run.source_version
    source_record = version.source_record

    unless run.status == :succeeded and run.quality_measurements["accepted"] do
      raise "processing run has no accepted extraction quality decision"
    end

    artifact = accepted_text_artifact!(Ash.load!(run, :derived_artifacts))
    {:ok, text} = BrusselsWtf.Archive.get(artifact.object_key)

    if BrusselsWtf.Digest.sha256(text) != artifact.output_sha256 do
      raise "derived extraction artifact checksum mismatch"
    end

    case BrusselsWtf.Processors.normalize(processor_input(run, source_record, text)) do
      {:ok, normalized} ->
        persist_normalized(source_record, version, citation_url, normalized, generation_kind)

      {:error, :processor_unimplemented} ->
        BrusselsWtf.Ingestion.NormalizationReview.open_for_run(run, citation_url)
        :ok

      {:error, {:normalization_ambiguity, candidates}} when is_map(candidates) ->
        BrusselsWtf.Ingestion.NormalizationReview.open_for_run(
          run,
          citation_url,
          :normalization_ambiguity,
          candidates
        )

        :ok

      {:error, reason} ->
        if attempt >= max_attempts do
          BrusselsWtf.Ingestion.NormalizationReview.open_for_run(
            run,
            citation_url,
            :processor_failure,
            %{}
          )

          :ok
        else
          {:error, reason}
        end
    end
  end

  defp persist_normalized(source_record, version, citation_url, normalized, generation_kind) do
    meeting =
      Council.upsert_meeting!(%{
        commune_id: source_record.commune_id,
        municipal_identifier: normalized["meeting_identifier"],
        scheduled_on: Date.from_iso8601!(normalized["scheduled_on"])
      })

    Ingestion.link_source_record_to_meeting!(source_record, %{council_meeting_id: meeting.id})
    agenda = record_agenda(normalized["agenda"], meeting, version)

    Enum.each(List.wrap(normalized["items"]), fn candidate ->
      version_order =
        current_version_order(
          version,
          get_in(normalized, ["agenda", "kind"]),
          source_record.role
        )

      item =
        Council.upsert_agenda_item!(%{
          council_meeting_id: meeting.id,
          item_number: candidate["item_number"],
          authoritative_identifier: candidate["authoritative_identifier"],
          source_wording: candidate["source_wording"],
          current_source_version_id: version.id,
          current_version_order: version_order,
          procedural_state: :unknown,
          outcome: :unknown
        })

      Council.record_agenda_item_version!(%{
        agenda_item_id: item.id,
        source_version_id: version.id,
        agenda_id: agenda && agenda.id,
        authoritative_identifier: candidate["authoritative_identifier"],
        source_wording: candidate["source_wording"]
      })

      link_item_scoped_source!(source_record, item, candidate)

      if List.wrap(candidate["proposals"]) != [] and item.procedural_state != :decision do
        Council.mark_agenda_item_proposed!(item)
      end

      record_proposals(candidate["proposals"], item, version, version_order, citation_url)
      record_decisions(candidate["decisions"], item, version, source_record.role, citation_url)
    end)

    Council.upsert_meeting_page!(%{
      council_meeting_id: meeting.id,
      citation_url: citation_url,
      procedural_state: :unknown
    })

    if generation_kind != :backfill do
      %{meeting_id: meeting.id, generation_kind: "automatic"}
      |> Workers.PublishMeeting.new()
      |> Oban.insert!()
    end

    :ok
  end

  defp discover(commune, body) do
    with {:ok, adapter} <- BrusselsWtf.Communes.adapter(commune.slug) do
      adapter.discover(body, commune.index_url)
    end
  end

  defp archive_index(locator, response, body, now) do
    existing = existing_record(locator.commune_id, locator.url)
    sha256 = BrusselsWtf.Digest.sha256(body)
    existed? = existing && Enum.any?(existing.versions, &(&1.sha256 == sha256))

    with {:ok, %{sha256: ^sha256, object_key: object_key}} <- BrusselsWtf.Archive.store(body) do
      source_record =
        Ingestion.upsert_source_record!(%{
          commune_id: locator.commune_id,
          origin_url: locator.url,
          role: :index,
          original_language: locator.language
        })

      version =
        Ingestion.upsert_source_version!(%{
          source_record_id: source_record.id,
          sha256: sha256,
          byte_size: byte_size(body),
          media_type: media_type(response, locator.url),
          object_key: object_key,
          first_retrieved_at: now
        })

      {:ok, version, if(existed?, do: :unchanged, else: :success)}
    end
  end

  defp enqueue_document_fetches(commune_id, poll_run, check_key, discovered \\ nil) do
    locators =
      case {poll_run.kind, poll_run.scope, discovered} do
        {:scheduled, :previous_year, nil} ->
          commune_id
          |> Ingestion.list_document_locators!()
          |> previous_year_locators(BrusselsWtf.Clock.utc_now())
          |> Enum.filter(&due_now?/1)

        {:scheduled, :previous_year, locators} ->
          Enum.filter(locators, &due_now?/1)

        {:scheduled, :current, _discovered} ->
          Ingestion.list_due_locators!(BrusselsWtf.Clock.utc_now())
          |> Enum.filter(&(&1.commune_id == commune_id))

        {_manual_kind, _scope, nil} ->
          Ingestion.list_document_locators!(commune_id)

        {_manual_kind, _scope, locators} ->
          locators
      end

    locators =
      if is_nil(discovered) and not (poll_run.kind == :scheduled and poll_run.scope == :current) do
        index_url =
          commune_id
          |> Ingestion.get_commune!()
          |> BrusselsWtf.Communes.poll_index_url(poll_run.scope)

        locators
        |> Enum.filter(&(&1.parent_index_url == index_url))
        |> Enum.reject(&disappeared?/1)
      else
        locators
      end

    locators
    |> Enum.reject(&disappeared?/1)
    |> Enum.filter(&(&1.role in (@processable_roles ++ @listing_roles)))
    |> Enum.each(fn locator ->
      %{
        locator_id: locator.id,
        poll_run_id: poll_run.id,
        check_key: check_key,
        attempt: 1
      }
      |> Workers.FetchLocator.new()
      |> Oban.insert!()
    end)
  end

  defp due_now?(%{next_fetch_at: nil}), do: false

  defp due_now?(%{next_fetch_at: next_fetch_at}) do
    DateTime.compare(next_fetch_at, BrusselsWtf.Clock.utc_now()) in [:lt, :eq]
  end

  defp scope_discovered(discovered, :previous_year, now),
    do: previous_year_locators(discovered, now)

  defp scope_discovered(discovered, _scope, _now), do: discovered

  defp previous_year_locators(locators, now) do
    previous_year = DateTime.to_date(now).year - 1

    Enum.filter(locators, fn
      %{scheduled_on: %Date{year: ^previous_year}} -> true
      _locator -> false
    end)
  end

  defp initial_next_fetch_at(_locator, now, :scheduled, :previous_year, true), do: now

  defp initial_next_fetch_at(locator, now, :scheduled, _scope, _new_locator?) do
    case BrusselsWtf.Ingestion.PollSchedule.next_fetch_at(locator, now) do
      :stop -> nil
      _next -> now
    end
  end

  defp initial_next_fetch_at(locator, now, :poll_now, _scope, true) do
    case BrusselsWtf.Ingestion.PollSchedule.next_fetch_at(locator, now) do
      :stop -> nil
      _next -> now
    end
  end

  defp initial_next_fetch_at(_locator, _now, _manual_kind, _scope, _new_locator?), do: nil

  defp reactivate_if_rediscovered(locator, _now, kind, _scope)
       when kind in [:poll_now, :backfill],
       do: locator

  defp reactivate_if_rediscovered(locator, now, :scheduled, scope) do
    latest_observation = locator.id |> Ingestion.list_observations!() |> List.last()

    cond do
      match?(%{status: :disappeared}, latest_observation) ->
        Ingestion.schedule_locator_fetch!(locator, %{next_fetch_at: now})

      is_nil(latest_observation) and scope == :previous_year ->
        Ingestion.schedule_locator_fetch!(locator, %{next_fetch_at: now})

      true ->
        locator
    end
  end

  defp disappeared?(locator) do
    case List.last(Ingestion.list_observations!(locator.id)) do
      %{status: :disappeared} -> true
      _ -> false
    end
  end

  defp archive_success(locator, poll_run_id, check_key, response, body, now) do
    case BrusselsWtf.Archive.store(body) do
      {:ok, archived} ->
        version =
          persist_archived_source(
            locator,
            poll_run_id,
            check_key,
            response,
            Map.put(archived, :byte_size, byte_size(body)),
            now
          )

        if locator.role in @listing_roles do
          discover_nested_and_enqueue(locator, poll_run_id, check_key, body, now)
        else
          enqueue_source_processing(locator, poll_run_id, version)
        end

      {:error, reason} ->
        archive_failure(locator, poll_run_id, check_key, response, reason)
    end
  end

  defp archive_file_success(locator, poll_run_id, check_key, response, path, now) do
    case BrusselsWtf.Archive.store_file(path) do
      {:ok, archived} ->
        version =
          persist_archived_source(locator, poll_run_id, check_key, response, archived, now)

        enqueue_source_processing(locator, poll_run_id, version)

      {:error, reason} ->
        archive_failure(locator, poll_run_id, check_key, response, reason)
    end
  end

  defp persist_archived_source(
         locator,
         poll_run_id,
         check_key,
         response,
         %{sha256: sha256, object_key: object_key, byte_size: byte_size},
         now
       ) do
    existing = existing_record(locator.commune_id, locator.url)
    existed? = existing && Enum.any?(existing.versions, &(&1.sha256 == sha256))

    source_record =
      Ingestion.upsert_source_record!(%{
        commune_id: locator.commune_id,
        origin_url: locator.url,
        role: locator.role,
        original_language: locator.language
      })

    version =
      Ingestion.upsert_source_version!(%{
        source_record_id: source_record.id,
        sha256: sha256,
        byte_size: byte_size,
        media_type: media_type(response, locator.url),
        object_key: object_key,
        first_retrieved_at: now
      })

    unless existed? do
      BrusselsWtf.Ingestion.Observability.archive_stored(
        poll_run_id,
        locator.id,
        version.id,
        byte_size
      )
    end

    record_observation(locator, poll_run_id, response, check_key,
      status: if(existed?, do: :unchanged, else: :success),
      sha256: sha256,
      source_version_id: version.id
    )

    version
  end

  defp enqueue_source_processing(locator, poll_run_id, version) do
    cond do
      not Ingestion.SourceLimits.processing_allowed?(version) ->
        open_deferred_extraction(version, locator.commune_id)
        :ok

      locator.role in @processable_roles and not processed?(version) ->
        poll_run = Ingestion.get_poll_run!(poll_run_id)

        %{source_version_id: version.id, generation_kind: generation_kind(poll_run)}
        |> Workers.ExtractSource.new()
        |> Oban.insert!()

        :ok

      true ->
        :ok
    end
  end

  defp open_deferred_extraction(version, commune_id) do
    BrusselsWtf.Review.open_review_case!(%{
      kind: :extraction,
      commune_id: commune_id,
      affected_record_id: version.id,
      affected_record_type: "source_version",
      source_record_id: version.source_record_id,
      source_version_id: version.id,
      processing_generation: "large-source-acquisition-v1",
      urgency: :normal,
      summary:
        "Source archived; extraction deferred because it exceeds the processing size limit",
      diagnostics: %{
        "classification" => "resource_limit",
        "byte_size" => version.byte_size,
        "acquisition_limit" => Ingestion.SourceLimits.supporting_document_limit(),
        "processing_limit" => Ingestion.SourceLimits.processing_limit()
      }
    })
  end

  defp archive_failure(locator, poll_run_id, check_key, response, reason) do
    record_observation(locator, poll_run_id, response, check_key,
      status: :failure,
      error_kind: "archive_verification_failed",
      error_message: safe_error(reason)
    )

    {:review, :corruption}
  end

  defp enqueue_known_children(parent, poll_run_id, check_key) do
    parent.commune_id
    |> Ingestion.list_document_locators!()
    |> Enum.filter(&(&1.parent_index_url == parent.url))
    |> Enum.reject(&disappeared?/1)
    |> Enum.each(fn child ->
      %{
        locator_id: child.id,
        poll_run_id: poll_run_id,
        check_key: check_key,
        attempt: 1
      }
      |> Workers.FetchLocator.new()
      |> Oban.insert!()
    end)
  end

  defp discover_nested_and_enqueue(locator, poll_run_id, check_key, body, now) do
    commune = Ingestion.get_commune!(locator.commune_id)

    with {:ok, adapter} <- BrusselsWtf.Communes.adapter(commune.slug),
         true <- function_exported?(adapter, :discover_children, 2),
         {:ok, discovered} <- adapter.discover_children(body, locator) do
      stored =
        Enum.map(discovered, fn child ->
          Ingestion.upsert_locator!(%{
            commune_id: commune.id,
            url: child.url,
            parent_index_url: child.parent_index_url,
            meeting_identifier: child.meeting_identifier,
            scheduled_on: child.scheduled_on,
            role: child.role,
            language: child.language,
            observed_label: child.observed_label,
            item_identifier: child.item_identifier,
            dossier_identifier: Map.get(child, :dossier_identifier),
            discovered_at: now,
            next_fetch_at: now
          })
        end)

      mark_nested_disappeared(locator, poll_run_id, check_key, stored, now)

      Enum.each(stored, fn child ->
        %{
          locator_id: child.id,
          poll_run_id: poll_run_id,
          check_key: check_key,
          attempt: 1
        }
        |> Workers.FetchLocator.new()
        |> Oban.insert!()
      end)

      :ok
    else
      false -> {:review, :parser_ambiguity}
      {:error, _reason} -> {:review, :parser_ambiguity}
    end
  end

  defp mark_nested_disappeared(parent, poll_run_id, check_key, stored, now) do
    discovered_ids = MapSet.new(stored, & &1.id)

    parent.commune_id
    |> Ingestion.list_document_locators!()
    |> Enum.filter(&(&1.parent_index_url == parent.url))
    |> Enum.reject(&MapSet.member?(discovered_ids, &1.id))
    |> Enum.each(fn child ->
      Ingestion.record_observation!(%{
        source_locator_id: child.id,
        poll_run_id: poll_run_id,
        check_key: "#{check_key}:nested:#{child.id}",
        observed_at: now,
        status: :disappeared,
        final_url: child.url,
        error_kind: "disappeared_from_parent_listing",
        error_message: "locator was absent from its authoritative parent listing"
      })
    end)
  end

  defp record_agenda(nil, _meeting, _version), do: nil

  defp record_agenda(agenda, meeting, version) do
    Council.record_agenda!(%{
      council_meeting_id: meeting.id,
      source_version_id: version.id,
      kind: agenda_kind(agenda["kind"]),
      language: language(agenda["language"])
    })
  end

  defp interpretation_key(candidate) do
    candidate |> :erlang.term_to_binary([:deterministic]) |> BrusselsWtf.Digest.sha256()
  end

  defp record_proposals(proposals, item, version, version_order, citation_url) do
    Enum.each(List.wrap(proposals), fn candidate ->
      proposal =
        Council.record_proposal!(%{
          agenda_item_id: item.id,
          source_version_id: version.id,
          source_version_order: version_order,
          interpretation_key: interpretation_key(candidate),
          text: candidate["text"],
          status: :proposed
        })

      if evidence = candidate["evidence"] do
        Council.record_evidence!(%{
          proposal_id: proposal.id,
          source_version_id: version.id,
          claim: :proposal,
          excerpt: evidence["excerpt"],
          location: evidence["location"],
          citation_url: citation_url,
          retrieved_at: version.first_retrieved_at,
          applicable_from: parse_date(evidence["applicable_from"]),
          applicable_until: parse_date(evidence["applicable_until"])
        })
      end
    end)
  end

  defp link_item_scoped_source!(source_record, item, candidate) do
    locator =
      source_record.commune_id
      |> Ingestion.list_document_locators!()
      |> Enum.find(&(&1.url == source_record.origin_url and not is_nil(&1.item_identifier)))

    if locator do
      normalized_item = candidate["item_number"] |> to_string() |> String.trim_leading("0")
      locator_item = locator.item_identifier |> to_string() |> String.trim_leading("0")

      if normalized_item != locator_item do
        raise "normalized item does not match its authoritative item listing"
      end

      if locator.dossier_identifier &&
           candidate["authoritative_identifier"] != locator.dossier_identifier do
        raise "normalized dossier identifier does not match its authoritative listing"
      end

      Ingestion.link_source_record_to_agenda_item!(source_record, %{agenda_item_id: item.id})
    end
  end

  defp record_decisions(decisions, item, version, _source_role, citation_url) do
    decisions
    |> List.wrap()
    |> Enum.each(fn candidate ->
      decision =
        Council.record_decision!(%{
          agenda_item_id: item.id,
          source_version_id: version.id,
          interpretation_key: interpretation_key(candidate),
          disposition: disposition(candidate["disposition"]),
          statement: candidate["statement"],
          votes_for: get_in(candidate, ["vote", "for"]),
          votes_against: get_in(candidate, ["vote", "against"]),
          abstentions: get_in(candidate, ["vote", "abstentions"])
        })

      record_decision_evidence(candidate["evidence"], :decision, decision, version, citation_url)

      record_decision_evidence(
        get_in(candidate, ["vote", "evidence"]),
        :vote,
        decision,
        version,
        citation_url
      )

      if item.current_source_version_id == version.id do
        Council.mark_agenda_item_decided!(item, %{
          current_decision_id: decision.id,
          outcome: decision.disposition
        })
      end
    end)
  end

  defp record_decision_evidence(nil, _claim, _decision, _version, _citation_url), do: :ok

  defp record_decision_evidence(evidence, claim, decision, version, citation_url) do
    Council.record_decision_evidence!(%{
      decision_id: decision.id,
      source_version_id: version.id,
      claim: claim,
      excerpt: evidence["excerpt"],
      location: evidence["location"],
      citation_url: citation_url,
      retrieved_at: version.first_retrieved_at,
      applicable_from: parse_date(evidence["applicable_from"]),
      applicable_until: parse_date(evidence["applicable_until"])
    })
  end

  defp disposition(value)
       when value in ["approved", "rejected", "amended", "postponed", "withdrawn", "other"],
       do: String.to_existing_atom(value)

  defp disposition(value), do: raise("unsupported final disposition: #{inspect(value)}")

  defp mark_disappeared(commune_id, poll_run_id, check_key, discovered, now, scope) do
    discovered_ids = MapSet.new(Enum.map(discovered, & &1.id))
    parent_index_url = discovered |> List.first() |> Map.fetch!(:parent_index_url)

    commune_id
    |> Ingestion.list_document_locators!()
    |> Enum.filter(&(&1.parent_index_url == parent_index_url))
    |> scope_discovered(scope, now)
    |> Enum.reject(&MapSet.member?(discovered_ids, &1.id))
    |> Enum.each(fn locator ->
      observation =
        Ingestion.record_observation!(%{
          source_locator_id: locator.id,
          poll_run_id: poll_run_id,
          check_key: scheduled_check_key(check_key, locator.id),
          observed_at: now,
          status: :disappeared,
          final_url: locator.url,
          error_kind: "disappeared_from_index",
          error_message: "locator was absent from the authoritative index observation"
        })

      BrusselsWtf.Ingestion.Observability.retrieval(observation)
    end)
  end

  defp record_transport_failure(locator, poll_run_id, check_key, failure, now) do
    observation =
      Ingestion.record_observation!(%{
        source_locator_id: locator.id,
        poll_run_id: poll_run_id,
        check_key: check_key || scheduled_check_key(poll_run_id, locator.id),
        observed_at: now,
        status: :failure,
        final_url: Map.get(failure, :final_url, locator.url),
        response_headers: normalize_headers(Map.get(failure, :response_headers, %{})),
        redirect_chain: normalize_redirects(Map.get(failure, :redirect_chain, [])),
        error_kind: error_kind(failure.reason),
        error_message: safe_error(failure.reason)
      })

    BrusselsWtf.Ingestion.Observability.retrieval(observation)
    observation
  end

  defp record_observation(locator, poll_run_id, response, check_key, attrs) do
    observation =
      Ingestion.record_observation!(%{
        source_locator_id: locator.id,
        source_version_id: attrs[:source_version_id],
        poll_run_id: poll_run_id,
        check_key: check_key || scheduled_check_key(poll_run_id, locator.id),
        observed_at: BrusselsWtf.Clock.utc_now(),
        status: Keyword.fetch!(attrs, :status),
        http_status: response.status,
        sha256: attrs[:sha256],
        final_url: Map.get(response, :final_url, locator.url),
        response_headers: normalize_headers(Map.get(response, :headers, %{})),
        redirect_chain: normalize_redirects(Map.get(response, :redirect_chain, [])),
        error_kind: attrs[:error_kind],
        error_message: attrs[:error_message]
      })

    BrusselsWtf.Ingestion.Observability.retrieval(observation)
    observation
  end

  defp existing_record(commune_id, url) do
    case Ingestion.get_source_record_by_origin(commune_id, url) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp current_version(locator) do
    observation =
      locator.id
      |> Ingestion.list_observations!()
      |> Enum.reverse()
      |> Enum.find(fn observation ->
        observation.status in [:success, :unchanged] and not is_nil(observation.source_version_id)
      end)

    if observation, do: Ingestion.get_source_version!(observation.source_version_id)
  end

  defp processed?(version) do
    metadata = BrusselsWtf.PDF.Processor.metadata()

    version
    |> Ash.load!(:processing_runs)
    |> Map.fetch!(:processing_runs)
    |> Enum.any?(fn run ->
      run.processor_role == :native_extraction and
        run.processor_name == metadata.native_processor_name and
        run.processor_version == metadata.native_processor_version and
        run.config_hash == metadata.config_hash
    end)
  end

  defp scheduled_check_key(check_key, locator_id), do: "#{check_key}:locator:#{locator_id}"

  defp conditional_options(locator) do
    version = current_version(locator)

    observation =
      if version do
        locator.id
        |> Ingestion.list_observations!()
        |> Enum.reverse()
        |> Enum.find(fn observation ->
          observation.status in [:success, :unchanged] and
            observation.source_version_id == version.id and
            (Map.has_key?(observation.response_headers, "etag") or
               Map.has_key?(observation.response_headers, "last-modified"))
        end)
      end

    headers =
      %{}
      |> put_conditional_header("if-none-match", observation_header(observation, "etag"))
      |> put_conditional_header(
        "if-modified-since",
        observation_header(observation, "last-modified")
      )

    [headers: headers]
  end

  defp observation_header(nil, _name), do: nil

  defp observation_header(observation, name) do
    observation.response_headers |> Map.get(name, []) |> List.first()
  end

  defp put_conditional_header(headers, _name, nil), do: headers
  defp put_conditional_header(headers, name, value), do: Map.put(headers, name, [value])

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} -> {to_string(key), List.wrap(value)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    headers
    |> Enum.group_by(fn {key, _} -> to_string(key) end, fn {_, value} -> value end)
  end

  defp normalize_redirects(redirects) do
    Enum.map(redirects, fn redirect ->
      Map.new(redirect, fn {key, value} -> {to_string(key), value} end)
    end)
  end

  defp media_type(response, url) do
    response
    |> Map.get(:headers, %{})
    |> normalize_headers()
    |> Map.get("content-type", [])
    |> List.first()
    |> case do
      nil -> media_type_from_url(url)
      value -> value |> String.split(";", parts: 2) |> hd()
    end
  end

  defp media_type_from_url(url) do
    cond do
      String.ends_with?(url, ".pdf") -> "application/pdf"
      String.ends_with?(url, ".html") -> "text/html"
      true -> "application/octet-stream"
    end
  end

  defp newly_discovered?(locator_id) do
    locator_id
    |> Ingestion.list_observations!()
    |> Enum.all?(&(&1.status not in [:success, :unchanged]))
  end

  defp changed_observation?(locator_id, check_key) do
    locator_id
    |> Ingestion.list_observations!()
    |> Enum.any?(&(&1.check_key == check_key and &1.status == :success))
  end

  defp http_error_kind(_status, :disappeared), do: "disappeared"
  defp http_error_kind(_status, {:retry, _delay}), do: "transient_http_status"
  defp http_error_kind(_status, {:review, classification}), do: Atom.to_string(classification)
  defp http_error_kind(_status, _decision), do: "http_status"

  defp error_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_kind({kind, _}) when is_atom(kind), do: Atom.to_string(kind)
  defp error_kind(_), do: "transport_error"

  defp safe_error(reason),
    do: reason |> inspect(limit: 20, printable_limit: 500) |> String.slice(0, 1_000)

  defp record_succeeded_attempt(run, attempt, result, started_at, completed_at) do
    {_attempt, notifications} =
      Ingestion.record_processing_attempt!(
        %{
          processing_run_id: run.id,
          attempt: attempt,
          status: :succeeded,
          started_at: started_at,
          completed_at: completed_at,
          duration_ms: result.duration_ms,
          diagnostics: result.diagnostics,
          tool_versions: result.tool_versions,
          quality_measurements: result.quality_measurements
        },
        return_notifications?: true
      )

    notifications
  end

  defp record_failed_attempt(run, attempt, reason, started_at, duration_ms) do
    classification = Ingestion.ProcessingFailure.classify(reason)
    completed_at = BrusselsWtf.Clock.utc_now()

    Ingestion.record_processing_attempt!(%{
      processing_run_id: run.id,
      attempt: attempt,
      status: :failed,
      started_at: started_at,
      completed_at: completed_at,
      duration_ms: duration_ms,
      failure_classification: Atom.to_string(classification),
      diagnostics: %{
        "classification" => Atom.to_string(classification),
        "detail" => safe_failure_detail(reason)
      },
      tool_versions: BrusselsWtf.PDF.Processor.metadata().tool_versions,
      quality_measurements: failure_quality(reason)
    })
  end

  defp ensure_accepted_quality(%{"accepted" => true}), do: :ok
  defp ensure_accepted_quality(quality), do: {:error, {:quality_failure, quality}}

  defp failure_quality({:quality_failure, quality}) when is_map(quality), do: quality
  defp failure_quality(_reason), do: %{}

  defp safe_failure_detail({kind, detail}) when is_atom(kind) and is_atom(detail),
    do: %{"kind" => Atom.to_string(kind), "detail" => Atom.to_string(detail)}

  defp safe_failure_detail({kind, status}) when is_atom(kind) and is_integer(status),
    do: %{"kind" => Atom.to_string(kind), "exit_status" => status}

  defp safe_failure_detail({kind, {executable, status}})
       when is_atom(kind) and is_binary(executable) and is_integer(status),
       do: %{"kind" => Atom.to_string(kind), "executable" => executable, "exit_status" => status}

  defp safe_failure_detail({kind, {outcome, status}})
       when is_atom(kind) and is_atom(outcome) and is_integer(status),
       do: %{
         "kind" => Atom.to_string(kind),
         "outcome" => Atom.to_string(outcome),
         "exit_status" => status
       }

  defp safe_failure_detail(_reason), do: %{"detail" => "redacted"}

  defp elapsed_milliseconds(started_monotonic) do
    System.convert_time_unit(System.monotonic_time() - started_monotonic, :native, :millisecond)
  end

  defp extraction_summary(result, source_sha256) do
    %{
      "sha256" => source_sha256,
      "page_count" => result.page_count,
      "language_signals" => Map.get(result.output, "language_signals", %{}),
      "quality_accepted" => result.quality_measurements["accepted"]
    }
  end

  defp accepted_text_artifact!(run) do
    kind = if run.processor_role == :ocr, do: "ocr-text", else: "native-text"

    case Enum.filter(run.derived_artifacts, &(&1.output_kind == kind)) do
      [artifact] ->
        if artifact.quality_measurements["accepted"] do
          artifact
        else
          raise "processing run text artifact did not pass quality"
        end

      _ ->
        raise "processing run has no unique accepted text artifact"
    end
  end

  # Normalization consumes exactly one accepted text artifact plus the explicit
  # discovery context of the source locator. The lookup is read-only and a missing
  # locator degrades to nil identifiers instead of failing the run.
  defp processor_input(run, source_record, text) do
    run.output
    |> Map.put("text", text)
    |> Map.merge(source_context(source_record))
  end

  defp source_context(source_record) do
    locator = source_locator(source_record)

    %{
      "commune_slug" => commune_slug(source_record),
      "origin_url" => source_record.origin_url,
      "role" => locator_value(locator, & &1.role) || source_record.role,
      "language" => locator_value(locator, & &1.language) || source_record.original_language,
      "meeting_identifier" => locator_value(locator, & &1.meeting_identifier),
      "scheduled_on" => locator_value(locator, & &1.scheduled_on),
      "item_identifier" => locator_value(locator, & &1.item_identifier),
      "dossier_identifier" => locator_value(locator, & &1.dossier_identifier)
    }
    |> Map.new(fn {key, value} -> {key, context_value(value)} end)
  end

  defp source_locator(source_record) do
    source_record.commune_id
    |> Ingestion.list_document_locators!()
    |> Enum.find(&(&1.url == source_record.origin_url))
    |> case do
      nil ->
        source_record.commune_id
        |> Ingestion.list_locators!()
        |> Enum.find(&(&1.url == source_record.origin_url))

      locator ->
        locator
    end
  end

  defp commune_slug(%{commune: %{slug: slug}}), do: slug

  defp commune_slug(source_record),
    do: source_record |> Ash.load!(:commune) |> Map.fetch!(:commune) |> Map.fetch!(:slug)

  defp locator_value(nil, _getter), do: nil
  defp locator_value(locator, getter), do: getter.(locator)

  defp context_value(nil), do: nil
  defp context_value(value) when is_atom(value), do: Atom.to_string(value)
  defp context_value(%Date{} = value), do: Date.to_iso8601(value)
  defp context_value(value), do: value

  def fail_native_generation(source_version_id, classification) do
    metadata = BrusselsWtf.PDF.Processor.metadata()

    run =
      source_version_id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.find(fn candidate ->
        candidate.processor_role == :native_extraction and
          candidate.processor_name == metadata.native_processor_name and
          candidate.processor_version == metadata.native_processor_version and
          candidate.config_hash == metadata.config_hash
      end)

    fail_processing_run(run, classification)
  end

  def fail_processing_run(run, classification) do
    now = BrusselsWtf.Clock.utc_now()
    attempts = Ash.load!(run, :attempts).attempts
    latest_attempt = Enum.max_by(attempts, & &1.attempt, fn -> nil end)
    first_attempt = Enum.min_by(attempts, & &1.attempt, fn -> nil end)

    Ingestion.complete_processing_run!(run, %{
      status: :failed,
      failure_classification: Atom.to_string(classification),
      diagnostics:
        if(latest_attempt,
          do: latest_attempt.diagnostics,
          else: %{"classification" => Atom.to_string(classification)}
        ),
      tool_versions:
        if(latest_attempt,
          do: latest_attempt.tool_versions,
          else: BrusselsWtf.PDF.Processor.metadata().tool_versions
        ),
      quality_measurements:
        if(latest_attempt, do: latest_attempt.quality_measurements, else: %{}),
      started_at: if(first_attempt, do: first_attempt.started_at, else: now),
      completed_at: if(latest_attempt, do: latest_attempt.completed_at, else: now),
      duration_ms: Enum.reduce(attempts, 0, &(&1.duration_ms + &2)),
      output: %{"classification" => Atom.to_string(classification)}
    })
  end

  defp current_version_order(version, kind, source_role) do
    rank =
      case {kind, source_role} do
        {"final", _} ->
          60

        {_, role} when role in [:minutes, :register] ->
          60

        {"corrected", _} ->
          50

        {"addendum", _} ->
          40

        {_, role} when role in [:agenda_addendum, :addendum] ->
          40

        {_, role}
        when role in [
               :project,
               :explanatory_note,
               :complementary_explanatory_note,
               :explanatory_notes
             ] ->
          30

        {"supplement", _} ->
          20

        {"complementary", _} ->
          20

        {_, role} when role in [:complementary_agenda, :supplement] ->
          20

        {"base", _} ->
          10

        {_, :agenda} ->
          10

        _ ->
          0
      end

    "#{rank}:#{DateTime.to_iso8601(version.first_retrieved_at)}:#{version.sha256}"
  end

  defp parse_date(nil), do: nil
  defp parse_date(value), do: Date.from_iso8601!(value)

  defp agenda_kind("complementary"), do: :complementary
  defp agenda_kind("supplement"), do: :supplement
  defp agenda_kind("addendum"), do: :addendum
  defp agenda_kind("corrected"), do: :corrected
  defp agenda_kind("final"), do: :final
  defp agenda_kind(_), do: :base

  defp language("fr"), do: :fr
  defp language("nl"), do: :nl
  defp language("en"), do: :en
  defp language(_), do: :bilingual
  defp generation_kind(%{kind: :backfill}), do: "backfill"
  defp generation_kind(%{scope: :previous_year}), do: "backfill"
  defp generation_kind(%{}), do: "automatic"
  defp generation_kind(:backfill), do: "backfill"
  defp generation_kind("backfill"), do: "backfill"
  defp generation_kind(_kind), do: "automatic"
end
