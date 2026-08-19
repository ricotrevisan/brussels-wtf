defmodule BrusselsWtf.ReviewInboxAndActionsTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Review
  alias BrusselsWtf.Review.Actor

  defmodule ChangedPdfProcessor do
    @behaviour BrusselsWtf.PDF.Processor
    @impl true
    defdelegate native(meta, bytes), to: BrusselsWtf.PDF.Stub
    @impl true
    defdelegate ocr(meta, bytes, pages), to: BrusselsWtf.PDF.Stub

    @impl true
    def metadata do
      BrusselsWtf.PDF.Stub.metadata()
      |> Map.put(:native_processor_version, "fixture-poppler-changed")
      |> Map.put(:config_hash, "sha256:fixture-pdf-quality-changed")
    end
  end

  setup do
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-08-20 12:00:00Z])
    {:ok, actor: %Actor{id: "rico", role: :reviewer}}
  end

  test "cases converge within a generation and the inbox applies every required filter", %{
    actor: actor
  } do
    first = build_case!(kind: :extraction, generation: "gen-1", commune_slug: "ixelles")
    duplicate = build_case!(kind: :extraction, generation: "gen-1", commune_slug: "ixelles")
    second = build_case!(kind: :evidence, generation: "gen-2", commune_slug: "forest")

    assert duplicate.review_case.id == first.review_case.id
    assert second.review_case.id != first.review_case.id

    assert [case_record] =
             Review.list_review_cases!(
               %{
                 kind: :extraction,
                 commune_id: first.commune.id,
                 status: :open,
                 generation: "gen-1",
                 age_days: 7
               },
               actor: actor
             )

    assert case_record.id == first.review_case.id

    assert_raise Ash.Error.Forbidden, fn -> Review.list_review_cases!(%{}) end
  end

  test "named actions are Ash-authorized and append immutable audit effects", %{actor: actor} do
    context = build_case!()
    original_version = Ingestion.get_source_version!(context.version.id)
    assert {:ok, original_bytes} = BrusselsWtf.Archive.get(original_version.object_key)

    metadata = BrusselsWtf.PDF.Processor.metadata()

    failed_run =
      Ingestion.record_processing_run!(%{
        source_version_id: context.version.id,
        processor_name: metadata.native_processor_name,
        processor_version: metadata.native_processor_version,
        config_hash: metadata.config_hash,
        status: :failed,
        output: %{"error" => "quality failure"}
      })

    assert_raise Ash.Error.Invalid, fn ->
      Review.retry_review_case!(
        context.review_case,
        %{
          note: "duplicate processing identity",
          processor_name: "native-extraction",
          processor_version: "1",
          config_hash: "original-fixture"
        },
        actor: actor
      )
    end

    assert Ingestion.get_processing_run!(failed_run.id).status == :failed
    assert Review.get_review_case!(context.review_case.id, actor: actor).actions == []

    assert_raise Ash.Error.Forbidden, fn ->
      Review.retry_review_case!(context.review_case, %{
        note: "try the corrected extractor"
      })
    end

    updated =
      Review.retry_review_case!(
        context.review_case,
        %{
          note: "try the corrected extractor"
        },
        actor: actor
      )

    assert updated.status == :open
    assert updated.disposition == :retry_requested

    detail = Review.get_review_case!(updated.id, actor: actor)

    assert [
             %{
               action: :retry,
               actor_id: "rico",
               note: "try the corrected extractor",
               effect: :processing_generation
             }
           ] = detail.actions

    retry_run = Enum.find(detail.source_version.processing_runs, &(&1.status == :queued))
    assert %{id: retry_run_id, processor_name: "poppler-native-text"} = retry_run
    assert retry_run.generation_key == "review:#{hd(detail.actions).id}"
    assert retry_run.id != failed_run.id

    assert_enqueued(
      worker: BrusselsWtf.Workers.ExtractSource,
      args: %{source_version_id: context.version.id, processing_run_id: retry_run_id}
    )

    corrected_text =
      "Corrected Conseil communal Gemeenteraad extraction with sufficient official proposal text"

    BrusselsWtf.Processors.Stub.put(context.version.sha256, %{
      extract: %{"text" => corrected_text}
    })

    assert :ok =
             perform_job(BrusselsWtf.Workers.ExtractSource, %{
               source_version_id: context.version.id,
               processing_run_id: retry_run_id
             })

    completed = Review.get_review_case!(updated.id, actor: actor)
    assert completed.status == :resolved

    completed_retry =
      Enum.find(completed.source_version.processing_runs, &(&1.id == retry_run_id))

    assert %{status: :succeeded, output: %{"quality_accepted" => true}} = completed_retry
    [artifact] = Ash.load!(completed_retry, :derived_artifacts).derived_artifacts
    assert artifact.output_kind == "native-text"
    assert BrusselsWtf.Archive.get(artifact.object_key) == {:ok, corrected_text}
    assert Ingestion.get_processing_run!(failed_run.id).status == :failed

    unchanged_version = Ingestion.get_source_version!(context.version.id)
    assert unchanged_version.sha256 == original_version.sha256
    assert unchanged_version.object_key == original_version.object_key
    assert BrusselsWtf.Archive.get(unchanged_version.object_key) == {:ok, original_bytes}
  end

  test "a retried failed run reconciles a missing terminal review case", %{actor: actor} do
    context = build_case!(generation: "preexisting-case")
    metadata = BrusselsWtf.PDF.Processor.metadata()

    run =
      Ingestion.create_review_processing_run!(%{
        source_version_id: context.version.id,
        generation_key: "review:missing-case",
        processor_name: metadata.native_processor_name,
        processor_version: metadata.native_processor_version,
        config_hash: metadata.config_hash,
        status: :queued
      })

    Ingestion.Pipeline.fail_processing_run(run, :resource_limit)

    refute Enum.any?(
             Review.list_review_cases!(%{status: :open}, actor: actor),
             &String.ends_with?(&1.processing_generation, run.id)
           )

    assert :ok = Ingestion.Pipeline.retry_extraction(run.id, 2)
    assert :ok = Ingestion.Pipeline.retry_extraction(run.id, 3)

    cases = Review.list_review_cases!(%{status: :open}, actor: actor)
    assert Enum.count(cases, &String.ends_with?(&1.processing_generation, run.id)) == 1
  end

  test "retry execution fails closed if deployed processor provenance changed", %{actor: actor} do
    context = build_case!(generation: "provenance-race")
    original_processor = Application.fetch_env!(:brussels_wtf, :pdf_processor)
    on_exit(fn -> Application.put_env(:brussels_wtf, :pdf_processor, original_processor) end)

    Review.retry_review_case!(
      context.review_case,
      %{note: "retry current processor"},
      actor: actor
    )

    [run] =
      context.version.id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)

    Application.put_env(:brussels_wtf, :pdf_processor, ChangedPdfProcessor)

    assert :ok =
             perform_job(
               BrusselsWtf.Workers.ExtractSource,
               %{source_version_id: context.version.id, processing_run_id: run.id},
               attempt: 1
             )

    failed = Ingestion.get_processing_run!(run.id) |> Ash.load!([:attempts, :derived_artifacts])
    assert failed.status == :failed
    assert failed.failure_classification == "configuration_mismatch"
    assert failed.derived_artifacts == []

    assert [%{failure_classification: "configuration_mismatch", diagnostics: diagnostics}] =
             failed.attempts

    assert diagnostics["detail"] == %{
             "kind" => "processor_provenance_mismatch",
             "detail" => "native_extraction"
           }
  end

  test "a terminal reviewer retry opens a case for the failed generation", %{actor: actor} do
    context = build_case!(generation: "original-generation")

    Review.retry_review_case!(
      context.review_case,
      %{
        note: "retry configured processor"
      },
      actor: actor
    )

    [retry_run] =
      context.version.id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)

    BrusselsWtf.Processors.Stub.put(context.version.sha256, %{
      extract: {:error, :temporary_unavailable}
    })

    assert :ok =
             perform_job(
               BrusselsWtf.Workers.ExtractSource,
               %{source_version_id: context.version.id, processing_run_id: retry_run.id},
               attempt: 3,
               max_attempts: 3
             )

    failed = Ingestion.get_processing_run!(retry_run.id)
    assert failed.status == :failed
    assert failed.failure_classification == "processor_failure"
    assert failed.started_at
    assert failed.completed_at
    assert failed.duration_ms >= 0

    assert [%{started_at: attempt_started, duration_ms: attempt_duration}] =
             Ash.load!(failed, :attempts).attempts

    assert failed.started_at == attempt_started
    assert failed.completed_at == hd(Ash.load!(failed, :attempts).attempts).completed_at
    assert failed.duration_ms == attempt_duration

    cases = Review.list_review_cases!(%{kind: :extraction, status: :open}, actor: actor)
    assert Enum.any?(cases, &(&1.id == context.review_case.id))
    assert Enum.any?(cases, &String.ends_with?(&1.processing_generation, retry_run.id))
    assert Enum.count(cases, &String.ends_with?(&1.processing_generation, retry_run.id)) == 1
  end

  test "source-specific revisions fail instead of auditing a no-op", %{actor: actor} do
    review_case =
      Review.open_review_case!(%{
        kind: :normalization,
        affected_record_id: Ecto.UUID.generate(),
        affected_record_type: "agenda_item",
        processing_generation: "no-source",
        summary: "No source record is attached"
      })

    assert_raise Ash.Error.Invalid, fn ->
      Review.reclassify_review_case!(
        review_case,
        %{note: "cannot apply", classification: :minutes},
        actor: actor
      )
    end

    assert Review.get_review_case!(review_case.id, actor: actor).actions == []
  end

  test "reclassify, relink, correct, and mark unsupported retain their typed dispositions", %{
    actor: actor
  } do
    expectations = [
      {:reclassify_review_case!, :reclassified, :domain_revision},
      {:relink_review_case!, :relinked, :domain_revision},
      {:correct_review_case!, :corrected, :domain_revision},
      {:mark_review_case_unsupported!, :unsupported, :exclusion}
    ]

    for {operation, disposition, effect} <- expectations do
      context = build_case!(generation: Atom.to_string(disposition))
      inputs = action_inputs(operation, context)

      updated = apply(Review, operation, [context.review_case, inputs, [actor: actor]])
      detail = Review.get_review_case!(updated.id, actor: actor)

      assert updated.disposition == disposition
      assert [%{effect: ^effect, disposition: ^disposition, actor_id: "rico"}] = detail.actions

      case effect do
        :domain_revision -> assert [%{actor_id: "rico", note: "reviewed"}] = detail.revisions
        :exclusion -> assert [%{actor_id: "rico", reason: "reviewed"}] = detail.exclusions
      end

      assert_domain_effect(operation, updated, context)

      if operation == :mark_review_case_unsupported! do
        assert_raise Ash.Error.Invalid, fn ->
          Review.retry_review_case!(
            updated,
            %{
              note: "should not retry"
            },
            actor: actor
          )
        end
      end
    end
  end

  defp action_inputs(:reclassify_review_case!, _context),
    do: %{note: "reviewed", classification: :minutes}

  defp action_inputs(:relink_review_case!, context),
    do: %{
      note: "reviewed",
      target_record_id: context.meeting.id,
      target_record_type: "council_meeting"
    }

  defp action_inputs(:correct_review_case!, _context),
    do: %{note: "reviewed", corrected_content: %{"title" => "Corrected title"}}

  defp action_inputs(:mark_review_case_unsupported!, _context),
    do: %{note: "reviewed", reason_code: "unsupported-media"}

  defp assert_domain_effect(:reclassify_review_case!, _updated, context) do
    assert Ingestion.get_source_record!(context.record.id).role == :minutes
  end

  defp assert_domain_effect(:relink_review_case!, _updated, context) do
    assert Ingestion.get_source_record!(context.record.id).council_meeting_id ==
             context.meeting.id
  end

  defp assert_domain_effect(:correct_review_case!, updated, _context) do
    assert updated.normalized_content == %{"title" => "Corrected title"}
  end

  defp assert_domain_effect(:mark_review_case_unsupported!, _updated, _context), do: :ok

  defp build_case!(overrides \\ []) do
    slug = Keyword.get(overrides, :commune_slug, "ixelles")
    generation = Keyword.get(overrides, :generation, "gen-1")
    kind = Keyword.get(overrides, :kind, :extraction)

    commune =
      Ingestion.create_commune!(%{
        slug: slug,
        name: String.capitalize(slug),
        index_url: "https://example.test/#{slug}/index"
      })

    meeting =
      BrusselsWtf.Council.upsert_meeting!(%{
        commune_id: commune.id,
        municipal_identifier: "review-target",
        scheduled_on: ~D[2026-08-30]
      })

    now = BrusselsWtf.Clock.utc_now()
    url = "https://example.test/#{slug}/agenda.pdf"
    bytes = "immutable source #{slug}"
    {:ok, archived} = BrusselsWtf.Archive.store(bytes)

    record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: url,
        role: :agenda,
        original_language: :fr
      })

    version =
      Ingestion.upsert_source_version!(%{
        source_record_id: record.id,
        sha256: archived.sha256,
        byte_size: byte_size(bytes),
        media_type: "application/pdf",
        object_key: archived.object_key,
        first_retrieved_at: now
      })

    review_case =
      Review.open_review_case!(%{
        kind: kind,
        commune_id: commune.id,
        affected_record_id: record.id,
        affected_record_type: "source_record",
        source_record_id: record.id,
        source_version_id: version.id,
        processing_generation: generation,
        urgency: :high,
        summary: "Native extraction quality failed",
        extracted_text: "broken extraction",
        normalized_content: %{"title" => "Candidate title"},
        quality_measurements: %{"text_ratio" => 0.12},
        diagnostics: %{"error" => "too little text"},
        related_evidence: %{"location" => "page 1"}
      })

    %{
      commune: commune,
      meeting: meeting,
      record: record,
      version: version,
      review_case: review_case,
      bytes: bytes
    }
  end
end
