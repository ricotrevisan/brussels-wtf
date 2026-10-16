defmodule BrusselsWtf.Ingestion.LargePdfRecoveryTest do
  use BrusselsWtf.DataCase, async: false
  alias BrusselsWtf.{Ingestion, Review}
  alias BrusselsWtf.Ingestion.LargePdfRecovery

  defmodule FileProcessorStub do
    def metadata do
      %{
        native_processor_name: "large-file-native",
        native_processor_version: "fixture-1",
        config_hash:
          if(Application.get_env(:brussels_wtf, :large_pdf_test_mode) == :drift,
            do: "sha256:drift",
            else: "sha256:large-fixture-1"
          ),
        tool_versions: %{"poppler" => "fixture"}
      }
    end

    def native(meta, input, workspace, _opts \\ []) do
      send(
        Application.fetch_env!(:brussels_wtf, :large_pdf_test_pid),
        {:native, meta, input, workspace}
      )

      if Application.get_env(:brussels_wtf, :large_pdf_test_mode) == :concurrent do
        send(
          Application.fetch_env!(:brussels_wtf, :large_pdf_test_pid),
          {:native_process, self()}
        )

        receive do
          :continue -> :ok
        after
          25_000 -> raise "test barrier expired"
        end
      end

      text =
        if Application.get_env(:brussels_wtf, :large_pdf_test_mode) == :rejected,
          do: "",
          else: "Conseil communal proposition publique officielle pour la séance du conseil."

      path = Path.join(workspace, "native.txt")
      File.write!(path, text)
      File.chmod!(path, 0o600)
      quality = BrusselsWtf.PDF.Quality.assess([text])

      case Application.get_env(:brussels_wtf, :large_pdf_test_mode) do
        :timeout ->
          Process.sleep(5)
          {:error, {:processor_limit, :wall_time}}

        :exception ->
          raise "private processor text #{workspace}"

        :transport ->
          {:error, :archive_timeout}

        :invalid_quality ->
          {:ok,
           %{
             text_path: path,
             text_byte_size: byte_size(text),
             page_count: 0,
             quality_measurements: BrusselsWtf.PDF.Quality.assess([]),
             output: %{},
             diagnostics: %{},
             tool_versions: metadata().tool_versions,
             duration_ms: 1
           }}

        _ ->
          {:ok,
           %{
             text_path: path,
             text_byte_size: byte_size(text),
             page_count: 1,
             quality_measurements: quality,
             output: %{"page_count" => 1},
             diagnostics: %{},
             tool_versions: metadata().tool_versions,
             duration_ms: 1
           }}
      end
    end
  end

  setup do
    BrusselsWtf.Archive.Memory.reset()
    old_limits = Application.fetch_env!(:brussels_wtf, :pdf_limits)
    old_processor = Application.get_env(:brussels_wtf, :large_pdf_processor)
    Application.put_env(:brussels_wtf, :pdf_limits, %{old_limits | max_input_bytes: 32})
    Application.put_env(:brussels_wtf, :large_pdf_processor, FileProcessorStub)
    Application.put_env(:brussels_wtf, :large_pdf_test_pid, self())

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :pdf_limits, old_limits)

      if old_processor,
        do: Application.put_env(:brussels_wtf, :large_pdf_processor, old_processor),
        else: Application.delete_env(:brussels_wtf, :large_pdf_processor)

      Application.delete_env(:brussels_wtf, :large_pdf_test_pid)
      Application.delete_env(:brussels_wtf, :large_pdf_test_mode)
    end)

    commune =
      Ingestion.create_commune!(%{
        slug: "brussels",
        name: "Brussels",
        index_url: "https://example.test"
      })

    record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: "https://example.test/support.pdf",
        role: :supporting_document,
        original_language: :bilingual
      })

    bytes = "%PDF-1.7 " <> String.duplicate("x", 128)
    {:ok, archived} = BrusselsWtf.Archive.store(bytes)

    version =
      Ingestion.upsert_source_version!(%{
        source_record_id: record.id,
        sha256: archived.sha256,
        object_key: archived.object_key,
        byte_size: byte_size(bytes),
        media_type: "application/pdf",
        first_retrieved_at: BrusselsWtf.Clock.utc_now()
      })

    review_case =
      Review.open_review_case!(%{
        kind: :extraction,
        commune_id: commune.id,
        affected_record_id: version.id,
        affected_record_type: "source_version",
        source_record_id: record.id,
        source_version_id: version.id,
        processing_generation: "large-source-acquisition-v1",
        summary: "Extraction deferred",
        diagnostics: %{"classification" => "resource_limit"}
      })

    actor = %BrusselsWtf.Review.Actor{id: "reviewer", role: :reviewer}
    entry = %{case_id: review_case.id, source_version_id: version.id, sha256: version.sha256}
    {:ok, case: review_case, version: version, record: record, actor: actor, entry: entry}
  end

  test "recovery requires a reviewer and excludes explicitly unsupported cases", ctx do
    for actor <- [nil, %{id: "reader", role: :reader}, %{id: "system", role: :system}] do
      assert {:error, %Ash.Error.Forbidden{}} =
               LargePdfRecovery.request([ctx.entry], "unauthorized", actor: actor)
    end

    assert {:ok, _} =
             Review.mark_review_case_unsupported(
               ctx.case,
               %{note: "excluded input", reason_code: "unsupported"},
               actor: ctx.actor
             )

    assert {:error, _} =
             LargePdfRecovery.request([ctx.entry], "cannot bypass exclusion", actor: ctx.actor)

    assert Repo.all(Oban.Job) == []
  end

  test "shared native bytes preserve artifact links to each audited source generation", ctx do
    second = alternative_entry(ctx, %{})

    {:ok, runs} =
      LargePdfRecovery.request([ctx.entry, second], "shared bytes, distinct lineage",
        actor: ctx.actor
      )

    for job <- Repo.all(Oban.Job),
        do: assert(:ok == BrusselsWtf.Workers.ExtractLargeSource.perform(job))

    completed =
      Enum.map(runs, &(Ingestion.get_processing_run!(&1.id) |> Ash.load!(:derived_artifacts)))

    assert [first, second_run] = completed
    assert [first_artifact] = first.derived_artifacts
    assert [second_artifact] = second_run.derived_artifacts
    assert first_artifact.id == second_artifact.id
    assert first.generation_key != second_run.generation_key
    assert first_artifact.input_sha256 == ctx.version.sha256
    links = Ash.read!(Ingestion.ProcessingRunArtifact)

    assert MapSet.new(Enum.map(links, & &1.processing_run_id)) ==
             MapSet.new(Enum.map(runs, & &1.id))

    assert Enum.all?(completed, & &1.inputs["extraction_only"])
  end

  test "named action does not accept a caller-supplied hold or processor override", ctx do
    assert {:error, _} =
             Review.extract_large_native(
               ctx.case,
               %{
                 note: "cannot release",
                 source_version_id: ctx.version.id,
                 sha256: ctx.version.sha256,
                 extraction_only: false,
                 details: %{config_hash: "forged"}
               },
               actor: ctx.actor
             )

    assert Repo.all(Oban.Job) == []
  end

  test "the named action validates the persisted deferral rather than caller supplied case fields",
       ctx do
    entry = alternative_entry(ctx, %{kind: :normalization})
    review_case = Review.get_review_case!(entry.case_id, actor: ctx.actor)
    forged = %{review_case | kind: :extraction}

    assert {:error, _} =
             Review.extract_large_native(
               forged,
               %{
                 note: "must use stored context",
                 source_version_id: entry.source_version_id,
                 sha256: entry.sha256
               },
               actor: ctx.actor
             )

    assert Repo.all(Oban.Job) == []
  end

  test "request options cannot forge processor configuration or release the hold", ctx do
    for forged <- [
          config_hash: "forged",
          processor_name: "forged",
          extraction_only: false,
          processing_run_id: Ecto.UUID.generate()
        ] do
      assert {:error, _} =
               LargePdfRecovery.request([ctx.entry], "no override", [forged, {:actor, ctx.actor}])
    end

    assert Repo.all(Oban.Job) == []
  end

  test "five source allowlist is bounded and an invalid member rolls the entire batch back",
       ctx do
    entries = [ctx.entry | Enum.map(1..4, fn _ -> alternative_entry(ctx, %{}) end)]
    invalid = List.update_at(entries, 4, &%{&1 | sha256: String.duplicate("0", 64)})
    assert {:error, _} = LargePdfRecovery.request(invalid, "atomic batch", actor: ctx.actor)
    assert Repo.all(Oban.Job) == []
    assert Ash.read!(Ingestion.ProcessingRun) == []
    assert Ash.read!(Review.Action, actor: ctx.actor) == []

    assert {:ok, runs} =
             LargePdfRecovery.request(entries, "exact bounded batch", actor: ctx.actor)

    assert length(runs) == 5

    assert MapSet.new(Enum.map(runs, & &1.source_version_id)) ==
             MapSet.new(Enum.map(entries, & &1.source_version_id))
  end

  @tag timeout: 40_000
  test "independent connections serialize a native run beyond the default 15 second transaction",
       ctx do
    concurrent_connection_probe(ctx, :slow)
  end

  @tag timeout: 15_000
  test "connection loss stops private IO and retries the same queued generation safely", ctx do
    concurrent_connection_probe(ctx, :disconnect)
  end

  @tag timeout: 15_000
  test "worker death requeues the original identity without committing an attempt", ctx do
    concurrent_connection_probe(ctx, :crash)
  end

  defp concurrent_connection_probe(ctx, mode) do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    probe = BrusselsWtf.CommittedProbe.start!()

    {:ok, {entry, run, job, notifications}} =
      probe.(fn ->
        Repo.transaction(fn ->
          {commune, commune_notifications} =
            Ingestion.create_commune!(
              %{
                slug: "large-test-#{Ecto.UUID.generate()}",
                name: "Isolated test",
                index_url: "https://example.test"
              },
              return_notifications?: true
            )

          {entry, entry_notifications} =
            alternative_entry(%{ctx | record: %{ctx.record | commune_id: commune.id}}, %{},
              return_notifications?: true
            )

          review_case = Review.get_review_case!(entry.case_id, actor: ctx.actor)

          {requested, request_notifications} =
            Review.extract_large_native!(
              review_case,
              %{
                note: "concurrent replay",
                source_version_id: entry.source_version_id,
                sha256: entry.sha256
              },
              actor: ctx.actor,
              return_notifications?: true
            )

          run = Ingestion.get_processing_run!(requested.__metadata__.large_processing_run_id)

          job =
            Repo.one!(
              from j in Oban.Job, where: fragment("?->>'processing_run_id'", j.args) == ^run.id
            )

          {entry, run, job, commune_notifications ++ entry_notifications ++ request_notifications}
        end)
      end)

    Ash.Notifier.notify(notifications)
    Application.put_env(:brussels_wtf, :large_pdf_test_mode, :concurrent)
    parent = self()
    # Unlinked monitored tasks cannot kill the fixture owner before cleanup.
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      first =
        Task.Supervisor.async_nolink(supervisor, fn ->
          probe.(fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:backend, backend})
            BrusselsWtf.Workers.ExtractLargeSource.perform(job)
          end)
        end)

      assert_receive {:backend, backend}, 2_000
      assert_receive {:native_process, first_worker}, 2_000
      assert_receive {:native, _, _, first_workspace}, 2_000
      on_exit(fn -> File.rm_rf(first_workspace) end)

      if mode == :slow do
        Process.sleep(16_000)
      else
        monitor = Process.monitor(first_worker)

        if mode == :disconnect do
          probe.(fn -> Repo.query!("SELECT pg_terminate_backend($1)", [backend]) end)
          assert_receive {:DOWN, ^monitor, :process, ^first_worker, _}, 3_000
          assert Task.await(first, 3_000) == {:error, :recovery_unavailable}
          refute File.exists?(first_workspace)
        else
          owner_monitor = Process.monitor(first.pid)
          Task.shutdown(first, :brutal_kill)
          assert_receive {:DOWN, ^owner_monitor, :process, _, _}, 3_000
          refute Process.alive?(first.pid)
          assert_receive {:DOWN, ^monitor, :process, ^first_worker, _}, 3_000
        end

        probe.(fn ->
          queued =
            Ingestion.get_processing_run!(run.id) |> Ash.load!([:attempts, :derived_artifacts])

          assert queued.status == :queued
          assert queued.attempts == []
          assert queued.derived_artifacts == []
        end)
      end

      second =
        Task.Supervisor.async_nolink(supervisor, fn ->
          probe.(fn ->
            send(parent, :second_started)
            BrusselsWtf.Workers.ExtractLargeSource.perform(job)
          end)
        end)

      assert_receive :second_started, 2_000

      if mode == :slow do
        refute_receive {:native_process, _}, 300
        send(first_worker, :continue)
        assert Task.await(first, 5_000) == :ok
      else
        assert_receive {:native_process, retry_worker}, 2_000
        send(retry_worker, :continue)
      end

      assert Task.await(second, 5_000) == :ok
      refute_receive {:native_process, _}, 100

      probe.(fn ->
        complete =
          Ingestion.get_processing_run!(run.id) |> Ash.load!([:attempts, :derived_artifacts])

        assert complete.status == :succeeded
        assert length(complete.attempts) == 1
        assert length(complete.derived_artifacts) == 1

        assert length(
                 Ash.load!(
                   Ingestion.get_source_version!(entry.source_version_id),
                   :processing_runs
                 ).processing_runs
               ) == 1
      end)
    after
      for pid <- Task.Supervisor.children(supervisor),
          do: Task.Supervisor.terminate_child(supervisor, pid)

      Supervisor.stop(supervisor)
    end
  end

  test "unexpected processor exceptions are sanitized, bounded, and clean private files", ctx do
    Application.put_env(:brussels_wtf, :large_pdf_test_mode, :exception)
    {:ok, [run]} = LargePdfRecovery.request([ctx.entry], "safe failures", actor: ctx.actor)
    [job] = Repo.all(Oban.Job)

    assert {:error, :processing_failed} =
             BrusselsWtf.Workers.ExtractLargeSource.perform(%{job | attempt: 1})

    assert_receive {:native, _, _, workspace}
    refute File.exists?(workspace)
    assert :ok = BrusselsWtf.Workers.ExtractLargeSource.perform(%{job | attempt: 3})
    failed = Ingestion.get_processing_run!(run.id)
    assert failed.status == :failed
    refute Jason.encode!(failed.diagnostics) =~ "private processor text"
    refute Jason.encode!(failed.diagnostics) =~ workspace
  end

  test "empty or inconsistent native page quality cannot become an accepted artifact", ctx do
    Application.put_env(:brussels_wtf, :large_pdf_test_mode, :invalid_quality)

    {:ok, [run]} =
      LargePdfRecovery.request([ctx.entry], "all original pages required", actor: ctx.actor)

    [job] = Repo.all(Oban.Job)
    assert :ok = BrusselsWtf.Workers.ExtractLargeSource.perform(%{job | attempt: 1})
    failed = Ingestion.get_processing_run!(run.id) |> Ash.load!(:derived_artifacts)
    assert failed.status == :failed
    assert failed.failure_classification == "invalid_content"
    assert failed.derived_artifacts == []
    assert Review.get_review_case!(ctx.case.id, actor: ctx.actor).status == :open
  end

  test "corrupt retained raw bytes are terminal before invoking the processor", ctx do
    {:ok, [run]} = LargePdfRecovery.request([ctx.entry], "verify raw bytes", actor: ctx.actor)

    Agent.update(
      BrusselsWtf.Archive.Memory,
      &Map.put(&1, ctx.version.object_key, String.duplicate("x", ctx.version.byte_size))
    )

    [job] = Repo.all(Oban.Job)
    assert :ok = BrusselsWtf.Workers.ExtractLargeSource.perform(%{job | attempt: 1})
    assert Ingestion.get_processing_run!(run.id).failure_classification == "corruption"
    refute_receive {:native, _, _, _}
  end

  test "completed replay verifies the linked text hash without rewriting immutable outputs",
       ctx do
    {:ok, [run]} = LargePdfRecovery.request([ctx.entry], "replay verification", actor: ctx.actor)
    [job] = Repo.all(Oban.Job)
    assert :ok = BrusselsWtf.Workers.ExtractLargeSource.perform(job)
    complete = Ingestion.get_processing_run!(run.id) |> Ash.load!(:derived_artifacts)
    [artifact] = complete.derived_artifacts
    Agent.update(BrusselsWtf.Archive.Memory, &Map.put(&1, artifact.object_key, "corrupted"))
    assert {:discard, _} = BrusselsWtf.Workers.ExtractLargeSource.perform(job)
    unchanged = Ingestion.get_processing_run!(run.id)
    assert unchanged.output == complete.output
    assert unchanged.updated_at == complete.updated_at
    cases = Review.list_review_cases!(%{}, actor: ctx.actor)

    assert Enum.any?(
             cases,
             &(&1.processing_generation == "extraction:#{run.id}" and
                 &1.diagnostics["classification"] == "corruption")
           )

    assert length(Repo.all(Oban.Job)) == 1
  end

  test "large worker refuses an ordinary or unaudited run ID without mutating it", ctx do
    metadata = FileProcessorStub.metadata()

    run =
      Ingestion.record_processing_run!(%{
        source_version_id: ctx.version.id,
        processor_name: metadata.native_processor_name,
        processor_version: metadata.native_processor_version,
        config_hash: metadata.config_hash,
        status: :queued,
        inputs: %{},
        output: %{}
      })

    assert {:discard, _} =
             BrusselsWtf.Workers.ExtractLargeSource.perform(%Oban.Job{
               args: %{"processing_run_id" => run.id},
               attempt: 1,
               max_attempts: 3
             })

    assert Ingestion.get_processing_run!(run.id).status == :queued
    refute_receive {:native, _, _, _}
    assert Repo.all(Oban.Job) == []
  end

  test "transport failures retain three immutable attempts and then stop", ctx do
    Application.put_env(:brussels_wtf, :large_pdf_test_mode, :transport)
    {:ok, [run]} = LargePdfRecovery.request([ctx.entry], "retry transport only", actor: ctx.actor)
    [job] = Repo.all(Oban.Job)

    for attempt <- 1..2 do
      assert {:error, :processing_failed} =
               BrusselsWtf.Workers.ExtractLargeSource.perform(%{job | attempt: attempt})

      assert Ingestion.get_processing_run!(run.id).status == :queued
    end

    assert :ok = BrusselsWtf.Workers.ExtractLargeSource.perform(%{job | attempt: 3})
    failed = Ingestion.get_processing_run!(run.id) |> Ash.load!(:attempts)
    assert failed.status == :failed
    assert length(failed.attempts) == 3
    assert Enum.sort(Enum.map(failed.attempts, & &1.attempt)) == [1, 2, 3]

    for _ <- 1..3 do
      assert_receive {:native, _, _, workspace}
      refute File.exists?(workspace)
    end

    assert :ok = BrusselsWtf.Workers.ExtractLargeSource.perform(%{job | attempt: 3})
    refute_receive {:native, _, _, _}
  end

  test "processor timeout is terminal and cleans the workspace without downstream work", ctx do
    Application.put_env(:brussels_wtf, :large_pdf_test_mode, :timeout)
    {:ok, [run]} = LargePdfRecovery.request([ctx.entry], "bounded wall time", actor: ctx.actor)
    [job] = Repo.all(Oban.Job)
    assert :ok = BrusselsWtf.Workers.ExtractLargeSource.perform(%{job | attempt: 1})
    assert_receive {:native, _, input, workspace}
    refute File.exists?(input)
    refute File.exists?(workspace)
    failed = Ingestion.get_processing_run!(run.id) |> Ash.load!(:derived_artifacts)
    assert failed.status == :failed
    assert failed.failure_classification == "resource_limit"
    assert failed.duration_ms >= 5
    assert failed.derived_artifacts == []
    refute Jason.encode!(failed.diagnostics) =~ workspace
    assert Review.get_review_case!(ctx.case.id, actor: ctx.actor).status == :open
    assert length(Repo.all(Oban.Job)) == 1
  end

  test "queued processor drift fails terminally before archive or native work", ctx do
    {:ok, [run]} =
      LargePdfRecovery.request([ctx.entry], "pin deployed configuration", actor: ctx.actor)

    Application.put_env(:brussels_wtf, :large_pdf_test_mode, :drift)
    [job] = Repo.all(Oban.Job)
    assert :ok = BrusselsWtf.Workers.ExtractLargeSource.perform(%{job | attempt: 1})
    refute_receive {:native, _, _, _}
    failed = Ingestion.get_processing_run!(run.id) |> Ash.load!([:attempts, :derived_artifacts])
    assert failed.status == :failed
    assert failed.failure_classification == "configuration_mismatch"
    assert [attempt] = failed.attempts
    assert attempt.status == :failed
    assert failed.derived_artifacts == []
    assert Review.get_review_case!(ctx.case.id, actor: ctx.actor).status == :open
    cases = Review.list_review_cases!(%{}, actor: ctx.actor)
    assert Enum.any?(cases, &(&1.processing_generation == "extraction:#{run.id}"))
  end

  test "ordinary pipeline entrypoints cannot release a held recovery run", ctx do
    {:ok, [run]} = LargePdfRecovery.request([ctx.entry], "held", actor: ctx.actor)
    [job] = Repo.all(Oban.Job)
    assert :ok = BrusselsWtf.Workers.ExtractLargeSource.perform(job)
    assert {:error, :extraction_only} = BrusselsWtf.Ingestion.Pipeline.retry_extraction(run.id)

    assert {:error, :extraction_only} =
             BrusselsWtf.Ingestion.Pipeline.normalize(run.id, ctx.record.origin_url)

    assert {:error, :extraction_only} = BrusselsWtf.Ingestion.Pipeline.extract(run.id)
    assert {:error, :extraction_only} = BrusselsWtf.Ingestion.Pipeline.ocr(run.id)

    assert {:discard, _} =
             BrusselsWtf.Workers.NormalizeSource.perform(%Oban.Job{
               args: %{"processing_run_id" => run.id, "locator_url" => ctx.record.origin_url},
               attempt: 3,
               max_attempts: 3
             })

    assert {:discard, _} =
             BrusselsWtf.Workers.ExtractSource.perform(%Oban.Job{
               args: %{"processing_run_id" => run.id},
               attempt: 1,
               max_attempts: 3
             })

    assert Repo.all(Oban.Job) |> Enum.map(& &1.worker) == [
             "BrusselsWtf.Workers.ExtractLargeSource"
           ]

    assert Ash.read!(BrusselsWtf.Council.Meeting) == []
  end

  test "ordinary OCR worker discards a held generation without terminally failing it", ctx do
    {:ok, [run]} = LargePdfRecovery.request([ctx.entry], "held", actor: ctx.actor)

    assert {:discard, _} =
             BrusselsWtf.Workers.OCRSource.perform(%Oban.Job{
               args: %{"processing_run_id" => run.id},
               attempt: 3,
               max_attempts: 3
             })

    after_run = Ingestion.get_processing_run!(run.id)
    assert after_run.status == :queued
    assert after_run.failure_classification == nil
    assert :ok = BrusselsWtf.Workers.ExtractLargeSource.perform(Repo.one!(Oban.Job))
    assert Ingestion.get_processing_run!(run.id).status == :succeeded
  end

  test "native rejection retains exact page quality and leaves the deferral open without OCR",
       ctx do
    Application.put_env(:brussels_wtf, :large_pdf_test_mode, :rejected)
    {:ok, [run]} = LargePdfRecovery.request([ctx.entry], "reject safely", actor: ctx.actor)
    [job] = Repo.all(Oban.Job)
    assert :ok = BrusselsWtf.Workers.ExtractLargeSource.perform(job)
    complete = Ingestion.get_processing_run!(run.id) |> Ash.load!(:derived_artifacts)
    assert complete.status == :succeeded
    assert complete.quality_measurements == BrusselsWtf.PDF.Quality.assess([""])
    assert [artifact] = complete.derived_artifacts
    assert artifact.quality_measurements["accepted"] == false
    assert complete.output["page_count"] == 1
    assert Review.get_review_case!(ctx.case.id, actor: ctx.actor).status == :open

    assert Repo.all(Oban.Job) |> Enum.map(& &1.worker) == [
             "BrusselsWtf.Workers.ExtractLargeSource"
           ]

    assert :ok = BrusselsWtf.Workers.ExtractLargeSource.perform(job)
    assert Review.get_review_case!(ctx.case.id, actor: ctx.actor).status == :open
  end

  test "native completion retains immutable lineage and removes its private workspace", ctx do
    {:ok, [run]} = LargePdfRecovery.request([ctx.entry], "native-only", actor: ctx.actor)
    [job] = Repo.all(Oban.Job)
    assert :ok = BrusselsWtf.Workers.ExtractLargeSource.perform(job)
    assert_receive {:native, meta, input, workspace}

    assert meta == %{
             sha256: ctx.version.sha256,
             media_type: "application/pdf",
             byte_size: ctx.version.byte_size
           }

    refute File.exists?(input)
    refute File.exists?(workspace)
    complete = Ingestion.get_processing_run!(run.id) |> Ash.load!([:derived_artifacts, :attempts])
    assert complete.status == :succeeded
    assert complete.quality_measurements["accepted"] == true
    assert complete.output["page_count"] == 1
    assert complete.inputs == run.inputs
    refute Map.has_key?(complete.output, "text")
    refute Jason.encode!(complete.output) =~ workspace
    assert [artifact] = complete.derived_artifacts
    assert artifact.output_kind == "native-text"
    assert artifact.input_sha256 == ctx.version.sha256
    assert artifact.source_version_id == ctx.version.id
    assert artifact.quality_measurements == complete.quality_measurements
    assert artifact.processor_name == run.processor_name
    assert {:ok, text} = BrusselsWtf.Archive.get(artifact.object_key)
    assert artifact.output_sha256 == BrusselsWtf.Digest.sha256(text)
    assert [attempt] = complete.attempts
    assert attempt.status == :succeeded
    assert Review.get_review_case!(ctx.case.id, actor: ctx.actor).status == :resolved

    assert Repo.all(Oban.Job) |> Enum.map(& &1.worker) == [
             "BrusselsWtf.Workers.ExtractLargeSource"
           ]

    assert :ok = BrusselsWtf.Workers.ExtractLargeSource.perform(job)
    refute_receive {:native, _, _, _}
    assert Ingestion.get_processing_run!(run.id).updated_at == complete.updated_at
  end

  test "recovery eligibility excludes ordinary files, other roles, and non-deferral cases", ctx do
    for overrides <- [
          %{byte_size: 32},
          %{byte_size: 0},
          %{byte_size: 167_772_161},
          %{media_type: "text/plain"},
          %{role: :agenda},
          %{role: :mandate_declaration},
          %{kind: :normalization},
          %{processing_generation: "ordinary-failure"},
          %{source_version_id: ctx.version.id}
        ] do
      entry = alternative_entry(ctx, overrides)
      assert {:error, _} = LargePdfRecovery.request([entry], "excluded", actor: ctx.actor)
      assert Ash.read!(Ingestion.ProcessingRun) == []
      assert Repo.all(Oban.Job) == []
    end

    assert {:error, _} =
             Review.retry_review_case(ctx.case, %{note: "ordinary retry"}, actor: ctx.actor)
  end

  defp alternative_entry(ctx, overrides, opts \\ []) do
    {record, record_notifications} =
      Ingestion.upsert_source_record!(
        %{
          commune_id: ctx.record.commune_id,
          origin_url: "https://example.test/#{Ecto.UUID.generate()}.pdf",
          role: Map.get(overrides, :role, :supporting_document),
          original_language: :bilingual
        },
        return_notifications?: true
      )

    {version, version_notifications} =
      Ingestion.upsert_source_version!(
        %{
          source_record_id: record.id,
          sha256: ctx.version.sha256,
          object_key: ctx.version.object_key,
          byte_size: Map.get(overrides, :byte_size, ctx.version.byte_size),
          media_type: Map.get(overrides, :media_type, "application/pdf"),
          first_retrieved_at: BrusselsWtf.Clock.utc_now()
        },
        return_notifications?: true
      )

    {review_case, case_notifications} =
      Review.open_review_case!(
        %{
          kind: Map.get(overrides, :kind, :extraction),
          commune_id: record.commune_id,
          source_record_id: record.id,
          source_version_id: Map.get(overrides, :source_version_id, version.id),
          affected_record_id: version.id,
          affected_record_type: "source_version",
          processing_generation:
            Map.get(overrides, :processing_generation, "large-source-acquisition-v1"),
          summary: "Deferred",
          diagnostics: %{"classification" => "resource_limit"}
        },
        return_notifications?: true
      )

    entry = %{case_id: review_case.id, source_version_id: version.id, sha256: version.sha256}
    notifications = record_notifications ++ version_notifications ++ case_notifications

    if opts[:return_notifications?] do
      {entry, notifications}
    else
      Ash.Notifier.notify(notifications)
      entry
    end
  end

  test "manifest is an exact nonduplicate allowlist of at most five", ctx do
    for entries <- [
          [],
          [ctx.entry, ctx.entry],
          List.duplicate(ctx.entry, 6),
          [Map.put(ctx.entry, :processor_name, "forged")],
          [Map.put(ctx.entry, :extraction_only, false)],
          [%{ctx.entry | sha256: "not-a-hash"}]
        ] do
      assert {:error, _} = LargePdfRecovery.request(entries, "bounded", actor: ctx.actor)
      assert Repo.all(Oban.Job) == []
      assert Ash.read!(Ingestion.ProcessingRun) == []
    end
  end

  test "UUID spelling aliases cannot duplicate a native recovery document", ctx do
    alias_entry = %{
      ctx.entry
      | case_id: String.upcase(ctx.entry.case_id),
        source_version_id: String.upcase(ctx.entry.source_version_id)
    }

    assert {:error, :invalid_manifest} =
             LargePdfRecovery.request([ctx.entry, alias_entry], "duplicate identity",
               actor: ctx.actor
             )

    assert Repo.all(Oban.Job) == []
    assert Ash.read!(Ingestion.ProcessingRun) == []
    assert Ash.read!(Review.Action, actor: ctx.actor) == []
  end

  test "hash mismatch fails closed without creating a generation", ctx do
    bad = %{ctx.entry | sha256: String.duplicate("0", 64)}
    assert {:error, _} = LargePdfRecovery.request([bad], "wrong hash", actor: ctx.actor)
    assert Repo.all(Oban.Job) == []
    assert Ash.read!(Ingestion.ProcessingRun) == []
    assert Ash.read!(Review.Action, actor: ctx.actor) == []
  end

  test "review request pins runtime provenance and queues only a held native generation", ctx do
    assert {:ok, [run]} =
             LargePdfRecovery.request([ctx.entry], "approved native-only", actor: ctx.actor)

    assert run.generation_key == "review:#{run.inputs["review_action_id"]}"
    assert run.inputs["extraction_only"] == true
    assert run.inputs["source_sha256"] == ctx.version.sha256
    assert run.processor_name == FileProcessorStub.metadata().native_processor_name
    assert run.config_hash == FileProcessorStub.metadata().config_hash
    review_case = Review.get_review_case!(ctx.case.id, actor: ctx.actor)
    assert review_case.status == :open
    assert [audit] = review_case.actions
    assert audit.actor_id == ctx.actor.id
    assert audit.details["operation"] == "extract_large_native"
    assert audit.details["sha256"] == ctx.version.sha256
    assert audit.id == run.inputs["review_action_id"]
    assert [job] = Repo.all(Oban.Job)
    assert job.worker == "BrusselsWtf.Workers.ExtractLargeSource"
    assert job.queue == "extract"
    assert job.max_attempts == 3
    assert job.args == %{"processing_run_id" => run.id}
  end

  test "named recovery action rejects an absent authenticated reviewer", ctx do
    changeset =
      Ash.Changeset.for_update(ctx.case, :extract_large_native, %{
        note: "native only",
        source_version_id: ctx.version.id,
        sha256: ctx.version.sha256
      })

    assert {:error, %Ash.Error.Forbidden{}} = Ash.update(changeset)
  end
end
