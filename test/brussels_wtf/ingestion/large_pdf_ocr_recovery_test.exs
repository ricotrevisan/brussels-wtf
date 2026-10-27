defmodule BrusselsWtf.Ingestion.LargePdfOcrRecoveryTest do
  use BrusselsWtf.DataCase, async: false

  if is_nil(System.get_env("OCR_TEST_WORKSPACE")),
    do: @moduletag(skip: "requires explicit private dedicated OCR tmpfs")

  alias BrusselsWtf.{Ingestion, Review}
  alias BrusselsWtf.Ingestion.LargePdfOcrRecovery, as: Recovery

  defmodule Processor do
    def ocr_metadata_accounted(_opts) do
      metadata = Map.merge(ocr_metadata(), %{cpu_ms: 100, duration_ms: 1})

      if Application.get_env(:brussels_wtf, :ocr_test_mode) == :drift,
        do: %{metadata | config_hash: "changed"},
        else: metadata
    end

    def ocr_page(meta, input, page, workspace, opts) do
      if Application.get_env(:brussels_wtf, :ocr_test_mode) == :error do
        send(Application.fetch_env!(:brussels_wtf, :ocr_test_pid), {:ocr_page, page, opts, input})
        {:error, :archive_timeout}
      else
        do_ocr_page(meta, input, page, workspace, opts)
      end
    end

    defp do_ocr_page(_meta, input, page, workspace, opts) do
      send(Application.fetch_env!(:brussels_wtf, :ocr_test_pid), {:ocr_page, page, opts, input})

      if Application.get_env(:brussels_wtf, :ocr_test_barrier) do
        send(Application.fetch_env!(:brussels_wtf, :ocr_test_pid), {:ocr_process, self()})

        receive do
          :continue -> :ok
        after
          30_000 -> raise "fixture barrier"
        end
      end

      dir = Path.join(workspace, "ocr-page-#{Ecto.UUID.generate()}")
      File.mkdir!(dir)

      text =
        if Application.get_env(:brussels_wtf, :ocr_test_mode) == :rejected,
          do: "\f",
          else:
            "Conseil communal récupération officielle de la page #{page} pour cette séance publique.\f"

      path = Path.join(dir, "ocr.text")
      pdf = Path.join(dir, "ocr.pdf")
      File.write!(path, text)
      File.write!(pdf, "%PDF-fixture-#{page}")

      {:ok,
       %{
         text_path: path,
         searchable_pdf_path: pdf,
         text_byte_size: byte_size(text),
         pdf_byte_size: File.stat!(pdf).size,
         page_count: 1,
         original_pages: [page],
         quality_measurements: BrusselsWtf.PDF.Quality.assess([String.trim_trailing(text, "\f")]),
         output: %{},
         diagnostics: %{},
         tool_versions: ocr_metadata().tool_versions,
         cpu_ms: 500,
         duration_ms: 1
       }}
    end

    def ocr_metadata do
      %{
        ocr_processor_name: "fixture-ocr",
        ocr_processor_version: "1",
        config_hash: "sha256:fixture-ocr",
        tool_versions: %{"ocrmypdf" => "fixture"}
      }
    end
  end

  setup do
    BrusselsWtf.Archive.Memory.reset()

    keys = [
      :large_pdf_ocr_processor,
      :pdf_limits,
      :process_role,
      :large_pdf_ocr_workspace,
      :ocr_test_pid,
      :ocr_test_mode
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:brussels_wtf, &1)})
    Application.put_env(:brussels_wtf, :process_role, :ocr)

    Application.put_env(
      :brussels_wtf,
      :large_pdf_ocr_workspace,
      System.fetch_env!("OCR_TEST_WORKSPACE")
    )

    Application.put_env(:brussels_wtf, :ocr_test_pid, self())
    Application.put_env(:brussels_wtf, :large_pdf_ocr_processor, Processor)
    limits = Application.fetch_env!(:brussels_wtf, :pdf_limits)
    Application.put_env(:brussels_wtf, :pdf_limits, %{limits | max_input_bytes: 32})

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        case v do
          {:ok, value} -> Application.put_env(:brussels_wtf, k, value)
          :error -> Application.delete_env(:brussels_wtf, k)
        end
      end)
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
        origin_url: "https://example.test/ocr.pdf",
        role: :supporting_document,
        original_language: :bilingual
      })

    bytes = "%PDF-1.7 " <> String.duplicate("x", 128)
    {:ok, archive} = BrusselsWtf.Archive.store(bytes)

    version =
      Ingestion.upsert_source_version!(%{
        source_record_id: record.id,
        sha256: archive.sha256,
        object_key: archive.object_key,
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
        summary: "Deferred"
      })

    actor = %BrusselsWtf.Review.Actor{id: "reviewer", role: :reviewer}

    audit =
      Review.record_review_action!(
        %{
          review_case_id: review_case.id,
          action: :retry,
          effect: :processing_generation,
          disposition: :retry_requested,
          note: "native first",
          details: %{
            "operation" => "extract_large_native",
            "extraction_only" => true,
            "sha256" => version.sha256,
            "source_version_id" => version.id,
            "processor_name" => "native-fixture",
            "processor_version" => "1",
            "config_hash" => "native-fixture"
          }
        },
        actor: actor
      )

    native =
      Ingestion.record_processing_run!(%{
        source_version_id: version.id,
        generation_key: "review:#{audit.id}",
        processor_name: "native-fixture",
        processor_version: "1",
        config_hash: "native-fixture",
        processor_role: :native_extraction,
        status: :succeeded,
        inputs: %{
          "operation" => "extract_large_native",
          "extraction_only" => true,
          "review_action_id" => audit.id,
          "review_case_id" => review_case.id,
          "source_sha256" => version.sha256
        },
        quality_measurements:
          BrusselsWtf.PDF.Quality.assess([
            "Conseil communal proposition publique officielle pour la séance du conseil.",
            "",
            ""
          ]),
        output: %{"page_count" => 3}
      })

    native_text =
      "Conseil communal proposition publique officielle pour la séance du conseil.\f\f\f"

    {:ok, archived_text} = BrusselsWtf.Archive.store(native_text, :derived)

    artifact =
      Ingestion.upsert_derived_artifact!(%{
        source_version_id: version.id,
        processing_run_id: native.id,
        input_sha256: version.sha256,
        output_sha256: archived_text.sha256,
        object_key: archived_text.object_key,
        byte_size: byte_size(native_text),
        processor_name: native.processor_name,
        processor_version: native.processor_version,
        config_hash: native.config_hash,
        output_kind: "native-text",
        media_type: "text/plain; charset=utf-8",
        quality_measurements: native.quality_measurements
      })

    Ingestion.link_processing_run_artifact!(%{
      processing_run_id: native.id,
      derived_artifact_id: artifact.id,
      role: :native_output
    })

    entry = %{
      case_id: review_case.id,
      source_version_id: version.id,
      sha256: version.sha256,
      native_run_id: native.id,
      original_pages: [2, 3]
    }

    %{entry: entry, actor: actor, native: native, version: version, case: review_case}
  end

  test "alternate UUID spellings cannot duplicate one document in a batch", ctx do
    duplicate = %{
      ctx.entry
      | source_version_id: String.upcase(ctx.entry.source_version_id),
        case_id: String.upcase(ctx.entry.case_id)
    }

    assert {:error, _} =
             Recovery.request([ctx.entry, duplicate], "No duplicate allowance", actor: ctx.actor)

    assert Repo.all(Oban.Job) == []
  end

  test "shared native content retains each source version's authoritative generation links",
       ctx do
    record =
      Ingestion.upsert_source_record!(%{
        commune_id: ctx.case.commune_id,
        origin_url: "https://example.test/shared.pdf",
        role: :supporting_document,
        original_language: :bilingual
      })

    version =
      Ingestion.upsert_source_version!(
        Map.merge(
          Map.take(ctx.version, [
            :sha256,
            :object_key,
            :byte_size,
            :media_type,
            :first_retrieved_at
          ]),
          %{source_record_id: record.id}
        )
      )

    review_case =
      Review.open_review_case!(%{
        kind: :extraction,
        commune_id: record.commune_id,
        source_record_id: record.id,
        source_version_id: version.id,
        affected_record_id: version.id,
        affected_record_type: "source_version",
        processing_generation: "large-source-acquisition-v1",
        summary: "Shared deferred bytes"
      })

    original_audit =
      Ash.get!(Review.Action, ctx.native.inputs["review_action_id"], actor: ctx.actor)

    audit =
      Review.record_review_action!(
        %{
          review_case_id: review_case.id,
          action: :retry,
          effect: :processing_generation,
          disposition: :retry_requested,
          note: "Shared native",
          details: Map.put(original_audit.details, "source_version_id", version.id)
        },
        actor: ctx.actor
      )

    native =
      Ingestion.record_processing_run!(
        Map.merge(
          Map.take(ctx.native, [
            :processor_role,
            :processor_name,
            :processor_version,
            :config_hash,
            :quality_measurements,
            :status,
            :output
          ]),
          %{
            source_version_id: version.id,
            generation_key: "review:#{audit.id}",
            inputs:
              Map.merge(ctx.native.inputs, %{
                "review_case_id" => review_case.id,
                "review_action_id" => audit.id
              })
          }
        )
      )

    [artifact] = Ash.load!(ctx.native, :derived_artifacts).derived_artifacts

    Ingestion.link_processing_run_artifact!(%{
      processing_run_id: native.id,
      derived_artifact_id: artifact.id,
      role: :native_output
    })

    entry = %{
      ctx.entry
      | case_id: review_case.id,
        source_version_id: version.id,
        native_run_id: native.id
    }

    assert {:ok, [run]} = Recovery.request([entry], "Keep independent lineage", actor: ctx.actor)
    assert run.source_version_id == version.id
    assert run.inputs["native_run_id"] == native.id
    job = Repo.one!(Oban.Job)
    assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(job)
    assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(job)
    assert Ingestion.get_processing_run!(run.id).status == :succeeded
    assert hd(Ash.load!(native, :derived_artifacts).derived_artifacts).id == artifact.id
  end

  test "database budget actions fence three claims and make settlement replay idempotent", ctx do
    {:ok, [run]} = Recovery.request([ctx.entry], "bounded claims", actor: ctx.actor)

    chunk =
      Ash.read!(Ingestion.ProcessingRun) |> Enum.find(&(&1.inputs["parent_run_id"] == run.id))

    original = Ash.read_one!(Ingestion.OcrRecoveryBudget)

    for attempt <- 1..3 do
      token = Ecto.UUID.generate()

      reserved =
        Ingestion.reserve_ocr_recovery_budget!(original, %{page_run_id: chunk.id, token: token})

      assert reserved.reservations[token]["attempt"] == attempt
      assert reserved.cpu_ms == 90_000 and reserved.wall_ms == 120_000

      assert {:error, _} =
               Ingestion.settle_ocr_recovery_budget(reserved, %{
                 token: token,
                 cpu_ms: 90_001,
                 wall_ms: 1,
                 output_bytes: 0
               })

      settled =
        Ingestion.settle_ocr_recovery_budget!(reserved, %{
          token: token,
          cpu_ms: 0,
          wall_ms: 0,
          output_bytes: 0
        })

      assert settled.cpu_ms == 0 and settled.wall_ms == 0

      replayed =
        Ingestion.settle_ocr_recovery_budget!(reserved, %{
          token: token,
          cpu_ms: 0,
          wall_ms: 0,
          output_bytes: 0
        })

      assert replayed.cpu_ms == 0 and replayed.wall_ms == 0
      assert map_size(replayed.reservations) == attempt
    end

    assert {:error, _} =
             Ingestion.reserve_ocr_recovery_budget(original, %{
               page_run_id: chunk.id,
               token: Ecto.UUID.generate()
             })
  end

  test "changed raw archive bytes fail before OCR and keep all native evidence", ctx do
    {:ok, [run]} = Recovery.request([ctx.entry], "hash check", actor: ctx.actor)

    Agent.update(
      BrusselsWtf.Archive.Memory,
      &Map.put(&1, ctx.version.object_key, String.duplicate("x", ctx.version.byte_size))
    )

    assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(Repo.one!(Oban.Job))
    refute_receive {:ocr_page, _, _, _}
    assert Ingestion.get_processing_run!(run.id).failure_classification == "corruption"
    assert Ingestion.get_processing_run!(ctx.native.id).updated_at == ctx.native.updated_at
  end

  test "rejected OCR retains both immutable page artifacts and never resolves the deferral",
       ctx do
    {:ok, [run]} =
      Recovery.request([%{ctx.entry | original_pages: [2]}], "retain rejected OCR",
        actor: ctx.actor
      )

    Application.put_env(:brussels_wtf, :ocr_test_mode, :rejected)
    assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(Repo.one!(Oban.Job))
    complete = Ingestion.get_processing_run!(run.id) |> Ash.load!(:derived_artifacts)
    assert complete.status == :succeeded
    assert complete.quality_measurements["rejected_pages"] == [2, 3]

    chunk =
      Ash.read!(Ingestion.ProcessingRun)
      |> Enum.find(&(&1.inputs["parent_run_id"] == run.id))
      |> Ash.load!(:derived_artifacts)

    assert Enum.sort(Enum.map(chunk.derived_artifacts, & &1.output_kind)) == [
             "ocr-page-pdf",
             "ocr-page-text"
           ]

    refute chunk.quality_measurements["accepted"]
    assert Review.get_review_case!(ctx.case.id, actor: ctx.actor).status == :open
    assert [artifact] = complete.derived_artifacts
    refute artifact.quality_measurements["accepted"]

    assert Enum.any?(
             Review.list_review_cases!(%{}, actor: ctx.actor),
             &(&1.processing_generation == "extraction:#{run.id}")
           )
  end

  test "duplicate original-page chunks cannot produce a final text artifact", ctx do
    {:ok, [run]} = Recovery.request([ctx.entry], "exact coverage", actor: ctx.actor)

    chunk =
      Ash.read!(Ingestion.ProcessingRun) |> Enum.find(&(&1.inputs["parent_run_id"] == run.id))

    Ingestion.record_processing_run!(
      Map.merge(
        Map.take(chunk, [
          :source_version_id,
          :processor_role,
          :inputs,
          :processor_name,
          :processor_version,
          :config_hash,
          :status,
          :output
        ]),
        %{generation_key: "#{run.generation_key}:duplicate"}
      )
    )

    assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(Repo.one!(Oban.Job))
    failed = Ingestion.get_processing_run!(run.id) |> Ash.load!(:derived_artifacts)
    assert failed.status == :failed
    assert failed.derived_artifacts == []
    refute_receive {:ocr_page, _, _, _}
  end

  test "ordinary role and invalid quota cannot admit OCR or spend document allowance", ctx do
    {:ok, [run]} = Recovery.request([ctx.entry], "isolation", actor: ctx.actor)
    job = Repo.one!(Oban.Job)
    Application.put_env(:brussels_wtf, :process_role, :app)
    assert {:discard, _} = BrusselsWtf.Workers.OcrLargeSource.perform(%{job | attempt: 3})
    assert Ingestion.get_processing_run!(run.id).status == :queued
    Application.put_env(:brussels_wtf, :process_role, :ocr)

    subdir =
      Path.join(
        Application.fetch_env!(:brussels_wtf, :large_pdf_ocr_workspace),
        "invalid-subdirectory"
      )

    File.mkdir!(subdir)
    File.chmod!(subdir, 0o700)
    on_exit(fn -> File.rmdir(subdir) end)
    Application.put_env(:brussels_wtf, :large_pdf_ocr_workspace, subdir)

    for attempt <- 1..2 do
      assert {:error, :ocr_worker_unavailable} =
               BrusselsWtf.Workers.OcrLargeSource.perform(%{job | attempt: attempt})

      assert Ingestion.get_processing_run!(run.id).status == :queued
    end

    assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(%{job | attempt: 3})
    failed = Ingestion.get_processing_run!(run.id) |> Ash.load!(:attempts)
    assert failed.status == :failed
    assert Enum.sort(Enum.map(failed.attempts, & &1.attempt)) == [1, 2, 3]
    assert Ash.read_one!(Ingestion.OcrRecoveryBudget).cpu_ms == 0
    refute_receive {:ocr_page, _, _, _}
  end

  test "foreign workspace entries and symlinks are never removed or admitted", ctx do
    {:ok, [run]} = Recovery.request([ctx.entry], "private quota", actor: ctx.actor)
    workspace = Application.fetch_env!(:brussels_wtf, :large_pdf_ocr_workspace)
    foreign = Path.join(workspace, "foreign-test-owned")
    File.write!(foreign, "must survive")
    on_exit(fn -> File.rm(foreign) end)

    assert {:error, :ocr_worker_unavailable} =
             BrusselsWtf.Workers.OcrLargeSource.perform(Repo.one!(Oban.Job))

    assert File.read!(foreign) == "must survive"
    assert Ash.read_one!(Ingestion.OcrRecoveryBudget).cpu_ms == 0
    assert Ingestion.get_processing_run!(run.id).status == :queued
    File.rm!(foreign)
    link = Path.join(workspace, "ocr-page-012345678901234567890123")
    File.ln_s!(workspace, link)
    on_exit(fn -> File.rm(link) end)

    assert {:error, :ocr_worker_unavailable} =
             BrusselsWtf.Workers.OcrLargeSource.perform(Repo.one!(Oban.Job))

    assert File.lstat!(link).type == :symlink
    File.rm!(link)
  end

  test "ordinary terminal workers cannot mutate either held chunks or their parent", ctx do
    {:ok, [run]} = Recovery.request([ctx.entry], "held", actor: ctx.actor)

    chunks =
      Ash.read!(Ingestion.ProcessingRun) |> Enum.filter(&(&1.inputs["parent_run_id"] == run.id))

    for current <- [run | chunks] do
      for worker <- [
            BrusselsWtf.Workers.ExtractSource,
            BrusselsWtf.Workers.OCRSource,
            BrusselsWtf.Workers.NormalizeSource
          ] do
        assert {:discard, _} =
                 worker.perform(%Oban.Job{
                   args: %{
                     "processing_run_id" => current.id,
                     "locator_url" => "https://example.test/ocr.pdf"
                   },
                   attempt: 3,
                   max_attempts: 3
                 })
      end

      unchanged = Ingestion.get_processing_run!(current.id) |> Ash.load!(:attempts)
      assert unchanged.status == :queued
      assert unchanged.attempts == []
    end

    assert Repo.all(Oban.Job) |> Enum.map(& &1.worker) == ["BrusselsWtf.Workers.OcrLargeSource"]
  end

  test "corrupt completed checkpoint is rejected before admitting another page", ctx do
    {:ok, [run]} = Recovery.request([ctx.entry], "verify resume", actor: ctx.actor)
    job = Repo.one!(Oban.Job)
    assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(job)
    assert_receive {:ocr_page, 2, _, _}

    completed =
      Ash.read!(Ingestion.ProcessingRun)
      |> Enum.find(&(&1.inputs["parent_run_id"] == run.id and &1.status == :succeeded))
      |> Ash.load!(:derived_artifacts)

    artifact = Enum.find(completed.derived_artifacts, &(&1.output_kind == "ocr-page-pdf"))
    Agent.update(BrusselsWtf.Archive.Memory, &Map.put(&1, artifact.object_key, "corrupted"))
    assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(job)
    refute_receive {:ocr_page, 3, _, _}
    assert Ingestion.get_processing_run!(run.id).failure_classification == "corruption"
    assert Ingestion.get_processing_run!(completed.id).status == :succeeded
  end

  test "queued OCR provenance drift is classified before an OCR invocation and never refunded",
       ctx do
    {:ok, [run]} = Recovery.request([ctx.entry], "pin tools", actor: ctx.actor)
    Application.put_env(:brussels_wtf, :ocr_test_mode, :drift)
    assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(Repo.one!(Oban.Job))
    refute_receive {:ocr_page, _, _, _}

    assert Ingestion.get_processing_run!(run.id).failure_classification ==
             "configuration_mismatch"

    budget = Ash.read_one!(Ingestion.OcrRecoveryBudget)
    assert budget.cpu_ms == 90_000
    assert budget.wall_ms == 120_000
  end

  test "unknown failed page cost retains the whole document reservation and previous checkpoint",
       ctx do
    {:ok, [run]} = Recovery.request([ctx.entry], "retain uncertainty", actor: ctx.actor)
    job = Repo.one!(Oban.Job)
    assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(job)
    Application.put_env(:brussels_wtf, :ocr_test_mode, :error)
    assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(job)
    budget = Ash.read_one!(Ingestion.OcrRecoveryBudget)
    assert budget.cpu_ms <= 90_000 and budget.cpu_ms >= 89_000
    assert budget.wall_ms == 120_000
    assert Ingestion.get_processing_run!(run.id).status == :failed

    chunks =
      Ash.read!(Ingestion.ProcessingRun) |> Enum.filter(&(&1.inputs["parent_run_id"] == run.id))

    assert Enum.count(chunks, &(&1.status == :succeeded)) == 1
    assert Enum.count(chunks, &(&1.status == :failed)) == 1
    assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(%{job | attempt: 3})
    assert map_size(Ash.read_one!(Ingestion.OcrRecoveryBudget).reservations) == 2
    assert Review.get_review_case!(ctx.case.id, actor: ctx.actor).status == :open
  end

  test "request refuses native provenance that differs from its original audit", ctx do
    forged =
      Ingestion.record_processing_run!(
        Map.merge(
          Map.take(ctx.native, [
            :source_version_id,
            :generation_key,
            :processor_version,
            :config_hash,
            :processor_role,
            :status,
            :inputs,
            :quality_measurements,
            :output
          ]),
          %{processor_name: "forged"}
        )
      )

    assert {:error, _} =
             Recovery.request([%{ctx.entry | native_run_id: forged.id}], "no forgery",
               actor: ctx.actor
             )

    assert Repo.all(Oban.Job) == []
  end

  test "request manifest excludes accepted native pages, unsorted duplicate pages, and overrides",
       ctx do
    for entry <- [
          Map.put(ctx.entry, :original_pages, [1]),
          Map.put(ctx.entry, :original_pages, [3, 2]),
          Map.put(ctx.entry, :original_pages, [2, 2]),
          Map.put(ctx.entry, :original_pages, []),
          Map.put(ctx.entry, :original_pages, [501]),
          Map.put(ctx.entry, :original_pages, Enum.to_list(1..33)),
          Map.put(ctx.entry, :processor_name, "forged"),
          Map.put(ctx.entry, :extraction_only, false),
          %{ctx.entry | sha256: String.duplicate("0", 64)}
        ] do
      assert {:error, _} = Recovery.request([entry], "invalid", actor: ctx.actor)
      assert Repo.all(Oban.Job) == []
    end
  end

  test "partial selection retains complete nonaccepted text and leaves the deferral open", ctx do
    {:ok, [run]} =
      Recovery.request([%{ctx.entry | original_pages: [2]}], "recover one", actor: ctx.actor)

    assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(Repo.one!(Oban.Job))
    complete = Ingestion.get_processing_run!(run.id) |> Ash.load!(:derived_artifacts)
    assert complete.status == :succeeded
    assert complete.quality_measurements["rejected_pages"] == [3]
    refute complete.quality_measurements["accepted"]
    assert [artifact] = complete.derived_artifacts
    assert artifact.output_kind == "ocr-text"
    assert Review.get_review_case!(ctx.case.id, actor: ctx.actor).status == :open
    assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(Repo.one!(Oban.Job))
    assert Ingestion.get_processing_run!(run.id).updated_at == complete.updated_at
  end

  @tag :review_fixes
  test "guard connections preserve Repo network options without inheriting the Ecto pool" do
    config = [
      hostname: "::1",
      port: 5432,
      database: "fixture",
      username: "fixture",
      password: "fixture",
      socket_options: [:inet6],
      ssl: [verify: :verify_peer],
      connect_timeout: 1234,
      handshake_timeout: 2345,
      parameters: [application_name: "fixture"],
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 10
    ]

    assert BrusselsWtf.Ingestion.LargePdfOcrExecution.guard_connection_options(config) ==
             Keyword.drop(config, [:pool, :pool_size])
  end

  @tag :review_fixes
  test "snoozed contention does not consume the first genuine admission failure", ctx do
    {:ok, [run]} = Recovery.request([ctx.entry], "wait safely", actor: ctx.actor)
    job = Repo.one!(Oban.Job)
    workspace = Application.fetch_env!(:brussels_wtf, :large_pdf_ocr_workspace)
    Application.put_env(:brussels_wtf, :large_pdf_ocr_workspace, System.tmp_dir!())

    try do
      # Two earlier snoozes rolled the attempt back; this is the first real attempt.
      assert {:error, :ocr_worker_unavailable} =
               BrusselsWtf.Workers.OcrLargeSource.perform(%{
                 job
                 | attempt: 1,
                   meta: %{"snoozed" => 2}
               })

      queued = Ingestion.get_processing_run!(run.id) |> Ash.load!(:attempts)
      assert queued.status == :queued
      assert [attempt] = queued.attempts
      assert attempt.attempt == 1
      refute_receive {:ocr_page, _, _, _}
    after
      Application.put_env(:brussels_wtf, :large_pdf_ocr_workspace, workspace)
    end
  end

  @tag :review_fixes
  test "contention at the final attempt is snoozed and persisted by the real Oban engine", ctx do
    {:ok, [owner_run]} =
      Recovery.request([%{ctx.entry | original_pages: [2]}], "first owner", actor: ctx.actor)

    {:ok, [waiting_run]} =
      Recovery.request([%{ctx.entry | original_pages: [2]}], "waiting generation",
        actor: ctx.actor
      )

    jobs = Repo.all(Oban.Job)
    owner_job = Enum.find(jobs, &(&1.args["processing_run_id"] == owner_run.id))
    waiting_job = Enum.find(jobs, &(&1.args["processing_run_id"] == waiting_run.id))

    waiting_job =
      waiting_job
      |> Ecto.Changeset.change(
        state: "executing",
        attempt: 3,
        attempted_at: DateTime.utc_now()
      )
      |> Repo.update!()

    Application.put_env(:brussels_wtf, :ocr_test_barrier, true)
    on_exit(fn -> Application.delete_env(:brussels_wtf, :ocr_test_barrier) end)
    owner = Task.async(fn -> BrusselsWtf.Workers.OcrLargeSource.perform(owner_job) end)

    try do
      assert_receive {:ocr_process, pid}, 2_000

      executor =
        Oban.config()
        |> Oban.Queues.Executor.new(waiting_job)
        |> Oban.Queues.Executor.resolve_worker()
        |> Oban.Queues.Executor.perform()
        |> Oban.Queues.Executor.normalize_state()

      assert executor.state == :snoozed
      assert executor.result == {:snooze, 30}
      send(pid, :continue)
      assert :ok = Task.await(owner, 3_000)

      Oban.Queues.Executor.ack_event(executor)
      rescheduled = Repo.get!(Oban.Job, waiting_job.id)
      assert rescheduled.state == "scheduled"
      assert rescheduled.attempt == 2
      assert rescheduled.max_attempts == 3
      assert rescheduled.meta["snoozed"] == 1

      assert Ingestion.get_processing_run!(waiting_run.id).status == :queued

      require Ash.Query

      waiting_budget =
        Ingestion.OcrRecoveryBudget
        |> Ash.Query.filter(processing_run_id == ^waiting_run.id)
        |> Ash.read_one!()

      assert waiting_budget.reservations == %{}
      assert waiting_budget.cpu_ms == 0
      assert waiting_budget.wall_ms == 0
    after
      Task.shutdown(owner, :brutal_kill)
    end
  end

  test "independent concurrent consumers cannot charge or fail another live page owner", ctx do
    Application.put_env(:brussels_wtf, :ocr_test_barrier, true)
    on_exit(fn -> Application.delete_env(:brussels_wtf, :ocr_test_barrier) end)
    {:ok, [run]} = Recovery.request([ctx.entry], "serialize", actor: ctx.actor)
    job = Repo.one!(Oban.Job)
    owner = Task.async(fn -> BrusselsWtf.Workers.OcrLargeSource.perform(job) end)
    assert_receive {:ocr_process, pid}, 2_000

    assert {:snooze, 30} =
             BrusselsWtf.Workers.OcrLargeSource.perform(%{job | attempt: 3})

    send(pid, :continue)
    assert :ok = Task.await(owner, 3_000)
    assert Ingestion.get_processing_run!(run.id).status == :queued
    budget = Ash.read_one!(Ingestion.OcrRecoveryBudget)
    assert budget.cpu_ms == 600
    assert map_size(budget.reservations) == 1
  end

  @tag :core_ocr
  test "page checkpoints resume into exactly one complete held artifact without native-page rewriting",
       ctx do
    assert {:ok, [run]} =
             Recovery.request([ctx.entry], "recover rejected pages", actor: ctx.actor)

    job = Repo.one!(Oban.Job)
    assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(job)
    assert_receive {:ocr_page, 2, opts2, _}
    assert opts2[:cpu_seconds] == 89
    assert Ingestion.get_processing_run!(run.id).status == :queued

    chunks =
      Ash.read!(Ingestion.ProcessingRun) |> Enum.filter(&(&1.inputs["parent_run_id"] == run.id))

    assert Enum.count(chunks, &(&1.status == :succeeded)) == 1
    assert Enum.find(chunks, &(&1.status == :succeeded)).diagnostics["cpu_ms"] == 600
    assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(job)
    assert_receive {:ocr_page, 3, opts3, _}
    assert opts3[:cpu_seconds] <= 89
    refute_receive {:ocr_page, 2, _, _}
    complete = Ingestion.get_processing_run!(run.id) |> Ash.load!(:derived_artifacts)
    assert complete.status == :succeeded
    assert complete.completed_at != nil
    assert complete.quality_measurements["accepted"]
    assert Enum.map(complete.output["page_manifest"], & &1["original_page"]) == [1, 2, 3]
    assert Enum.map(complete.output["page_manifest"], & &1["origin"]) == ["native", "ocr", "ocr"]
    assert [artifact] = complete.derived_artifacts
    assert artifact.output_kind == "ocr-text"
    assert {:ok, text} = BrusselsWtf.Archive.get(artifact.object_key)

    assert String.split(text, "\f") == [
             "Conseil communal proposition publique officielle pour la séance du conseil.",
             "Conseil communal récupération officielle de la page 2 pour cette séance publique.",
             "Conseil communal récupération officielle de la page 3 pour cette séance publique.",
             ""
           ]

    assert Map.take(Ingestion.get_processing_run!(ctx.native.id), [
             :id,
             :inputs,
             :output,
             :quality_measurements,
             :updated_at
           ]) == Map.take(ctx.native, [:id, :inputs, :output, :quality_measurements, :updated_at])

    assert Review.get_review_case!(ctx.case.id, actor: ctx.actor).status == :resolved

    assert {:error, :extraction_only} =
             BrusselsWtf.Ingestion.Pipeline.normalize(run.id, "https://example.test/ocr.pdf")

    assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(job)
    refute_receive {:ocr_page, _, _, _}
    assert File.ls!(Application.fetch_env!(:brussels_wtf, :large_pdf_ocr_workspace)) == []
    budget = Ash.read_one!(Ingestion.OcrRecoveryBudget)
    assert budget.cpu_ms == 1200
    assert Enum.count(budget.reservations, fn {_, r} -> r["phase"] == "assembly" end) == 1
    assert budget.wall_ms > 0 and budget.wall_ms < 120_000
  end

  @tag :guard_contract
  @tag timeout: 40_000
  test "independent OCR claims remain serialized beyond Repo's default checkout", ctx do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    probe = BrusselsWtf.CommittedProbe.start!()
    {run, job} = committed_fixture(ctx, probe)
    Application.put_env(:brussels_wtf, :ocr_test_barrier, true)
    on_exit(fn -> Application.delete_env(:brussels_wtf, :ocr_test_barrier) end)
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      owner =
        Task.Supervisor.async_nolink(supervisor, fn ->
          probe.(fn -> BrusselsWtf.Workers.OcrLargeSource.perform(job) end)
        end)

      assert_receive {:ocr_process, child}, 2_000
      Process.sleep(16_000)

      assert {:snooze, 30} =
               probe.(fn -> BrusselsWtf.Workers.OcrLargeSource.perform(%{job | attempt: 3}) end)

      refute_receive {:ocr_process, _}
      send(child, :continue)
      assert :ok = Task.await(owner, 3_000)

      probe.(fn ->
        assert Ingestion.get_processing_run!(run.id).status == :queued
        assert map_size(Ash.read_one!(Ingestion.OcrRecoveryBudget).reservations) == 1
      end)
    after
      for pid <- Task.Supervisor.children(supervisor),
          do: Task.Supervisor.terminate_child(supervisor, pid)

      Supervisor.stop(supervisor)
    end
  end

  @tag timeout: 15_000, capture_log: true
  test "ownership connection loss cancels live work without refunding the committed allowance",
       ctx do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    probe = BrusselsWtf.CommittedProbe.start!()
    {run, job} = committed_fixture(ctx, probe)
    Application.put_env(:brussels_wtf, :ocr_test_barrier, true)
    on_exit(fn -> Application.delete_env(:brussels_wtf, :ocr_test_barrier) end)
    parent = self()
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      owner =
        Task.Supervisor.async_nolink(supervisor, fn ->
          probe.(fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:ownership_backend, backend})
            BrusselsWtf.Workers.OcrLargeSource.perform(job)
          end)
        end)

      assert_receive {:ownership_backend, backend}, 2_000
      assert_receive {:ocr_process, child}, 2_000
      monitor = Process.monitor(child)
      probe.(fn -> Repo.query!("SELECT pg_terminate_backend($1)", [backend]) end)
      assert_receive {:DOWN, ^monitor, :process, ^child, _}, 3_000
      assert {:error, :ocr_recovery_unavailable} = Task.await(owner, 3_000)

      probe.(fn ->
        assert Ingestion.get_processing_run!(run.id).status == :queued
        budget = Ash.read_one!(Ingestion.OcrRecoveryBudget)
        assert budget.cpu_ms == 90_000 and budget.wall_ms == 120_000
        assert :ok = BrusselsWtf.Workers.OcrLargeSource.perform(%{job | attempt: 3})
        assert Ingestion.get_processing_run!(run.id).status == :failed
      end)
    after
      for pid <- Task.Supervisor.children(supervisor),
          do: Task.Supervisor.terminate_child(supervisor, pid)

      Supervisor.stop(supervisor)
    end
  end

  @tag timeout: 15_000, capture_log: true
  test "real worker death releases the execution guard but cannot restore unknown spending",
       ctx do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    probe = BrusselsWtf.CommittedProbe.start!()
    {run, job} = committed_fixture(ctx, probe)
    assert :ok = probe.(fn -> BrusselsWtf.Workers.OcrLargeSource.perform(job) end)
    assert_receive {:ocr_page, 2, _, _}
    Application.put_env(:brussels_wtf, :ocr_test_barrier, true)
    on_exit(fn -> Application.delete_env(:brussels_wtf, :ocr_test_barrier) end)
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      owner =
        Task.Supervisor.async_nolink(supervisor, fn ->
          probe.(fn -> BrusselsWtf.Workers.OcrLargeSource.perform(job) end)
        end)

      assert_receive {:ocr_process, child}, 2_000
      owner_monitor = Process.monitor(owner.pid)
      child_monitor = Process.monitor(child)
      Task.shutdown(owner, :brutal_kill)
      assert_receive {:DOWN, ^owner_monitor, :process, _, _}, 3_000
      assert_receive {:DOWN, ^child_monitor, :process, _, _}, 3_000
      refute Process.alive?(owner.pid)
      refute Process.alive?(child)

      probe.(fn ->
        assert Ingestion.get_processing_run!(run.id).status == :queued
        budget = Ash.read_one!(Ingestion.OcrRecoveryBudget)
        assert budget.wall_ms == 120_000
        assert Enum.count(budget.reservations, fn {_, r} -> r["settled"] end) == 1
      end)

      assert :ok =
               probe.(fn -> BrusselsWtf.Workers.OcrLargeSource.perform(%{job | attempt: 3}) end)

      probe.(fn ->
        failed = Ingestion.get_processing_run!(run.id)
        assert failed.status == :failed

        chunks =
          Ash.read!(Ingestion.ProcessingRun)
          |> Enum.filter(&(&1.inputs["parent_run_id"] == run.id))

        assert Enum.count(chunks, &(&1.status == :succeeded)) == 1
        assert map_size(Ash.read_one!(Ingestion.OcrRecoveryBudget).reservations) == 2
      end)
    after
      for pid <- Task.Supervisor.children(supervisor),
          do: Task.Supervisor.terminate_child(supervisor, pid)

      Supervisor.stop(supervisor)
    end
  end

  defp committed_fixture(ctx, probe) do
    probe.(fn ->
      commune =
        Ingestion.create_commune!(%{
          slug: "ocr-death-#{Ecto.UUID.generate()}",
          name: "Isolated fixture",
          index_url: "https://example.test"
        })

      record =
        Ingestion.upsert_source_record!(%{
          commune_id: commune.id,
          origin_url: "https://example.test/#{commune.id}.pdf",
          role: :supporting_document,
          original_language: :bilingual
        })

      bytes = "%PDF-1.7 " <> String.duplicate("x", 128) <> commune.id
      {:ok, archive} = BrusselsWtf.Archive.store(bytes)

      version =
        Ingestion.upsert_source_version!(%{
          source_record_id: record.id,
          sha256: archive.sha256,
          object_key: archive.object_key,
          byte_size: byte_size(bytes),
          media_type: "application/pdf",
          first_retrieved_at: BrusselsWtf.Clock.utc_now()
        })

      review_case =
        Review.open_review_case!(%{
          kind: :extraction,
          commune_id: commune.id,
          source_record_id: record.id,
          source_version_id: version.id,
          affected_record_id: version.id,
          affected_record_type: "source_version",
          processing_generation: "large-source-acquisition-v1",
          summary: "Isolated deferred fixture"
        })

      audit =
        Review.record_review_action!(
          %{
            review_case_id: review_case.id,
            action: :retry,
            effect: :processing_generation,
            disposition: :retry_requested,
            note: "Native fixture",
            details: %{
              "operation" => "extract_large_native",
              "extraction_only" => true,
              "source_version_id" => version.id,
              "sha256" => version.sha256,
              "processor_name" => ctx.native.processor_name,
              "processor_version" => ctx.native.processor_version,
              "config_hash" => ctx.native.config_hash
            }
          },
          actor: ctx.actor
        )

      native =
        Ingestion.record_processing_run!(%{
          source_version_id: version.id,
          generation_key: "review:#{audit.id}",
          processor_name: ctx.native.processor_name,
          processor_version: ctx.native.processor_version,
          config_hash: ctx.native.config_hash,
          processor_role: :native_extraction,
          status: :succeeded,
          quality_measurements: ctx.native.quality_measurements,
          inputs: %{
            "operation" => "extract_large_native",
            "extraction_only" => true,
            "source_sha256" => version.sha256,
            "review_case_id" => review_case.id,
            "review_action_id" => audit.id
          },
          output: ctx.native.output
        })

      text = "Conseil communal proposition publique officielle pour la séance du conseil.\f\f\f"
      {:ok, archived} = BrusselsWtf.Archive.store(text, :derived)

      artifact =
        Ingestion.upsert_derived_artifact!(%{
          source_version_id: version.id,
          processing_run_id: native.id,
          input_sha256: version.sha256,
          output_sha256: archived.sha256,
          object_key: archived.object_key,
          byte_size: byte_size(text),
          processor_name: native.processor_name,
          processor_version: native.processor_version,
          config_hash: native.config_hash,
          output_kind: "native-text",
          media_type: "text/plain; charset=utf-8",
          quality_measurements: native.quality_measurements
        })

      Ingestion.link_processing_run_artifact!(%{
        processing_run_id: native.id,
        derived_artifact_id: artifact.id,
        role: :native_output
      })

      entry = %{
        case_id: review_case.id,
        source_version_id: version.id,
        sha256: version.sha256,
        native_run_id: native.id,
        original_pages: [2, 3]
      }

      {:ok, [run]} = Recovery.request([entry], "Isolated worker probe", actor: ctx.actor)

      job =
        Repo.one!(
          from j in Oban.Job, where: fragment("?->>'processing_run_id'", j.args) == ^run.id
        )

      {run, job}
    end)
  end

  test "authenticated page-selective request pins a finite held generation", ctx do
    assert {:error, _} = Recovery.request([ctx.entry], "OCR only", actor: nil)
    assert {:ok, [run]} = Recovery.request([ctx.entry], "OCR only", actor: ctx.actor)
    assert run.inputs["original_pages"] == [2, 3]
    assert run.inputs["native_run_id"] == ctx.native.id
    assert run.inputs["extraction_only"] == true
    assert run.generation_key == "review:#{run.inputs["review_action_id"]}"
    assert run.processor_name == "fixture-ocr"
    assert [job] = Repo.all(Oban.Job)
    assert job.queue == "ocr"
    assert job.worker == "BrusselsWtf.Workers.OcrLargeSource"
    assert job.max_attempts == 3
    assert is_integer(BrusselsWtf.Workers.OcrLargeSource.timeout(job))
    assert Review.get_review_case!(ctx.case.id, actor: ctx.actor).status == :open
  end
end
