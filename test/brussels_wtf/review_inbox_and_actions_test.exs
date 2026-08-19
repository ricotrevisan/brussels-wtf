defmodule BrusselsWtf.ReviewInboxAndActionsTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Review
  alias BrusselsWtf.Review.Actor

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

    assert_raise Ash.Error.Forbidden, fn ->
      Review.retry_review_case!(context.review_case, %{note: "try the corrected extractor"})
    end

    updated =
      Review.retry_review_case!(
        context.review_case,
        %{note: "try the corrected extractor", details: %{"processor" => "native-extraction-v2"}},
        actor: actor
      )

    assert updated.status == :resolved
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

    assert [%{id: retry_run_id, processor_name: "review-retry", status: :queued}] =
             detail.source_version.processing_runs

    assert_enqueued(
      worker: BrusselsWtf.Workers.ExtractSource,
      args: %{source_version_id: context.version.id, processing_run_id: retry_run_id}
    )

    BrusselsWtf.Processors.Stub.put(context.version.sha256, %{
      extract: %{"text" => "corrected extraction"}
    })

    assert :ok =
             perform_job(BrusselsWtf.Workers.ExtractSource, %{
               source_version_id: context.version.id,
               processing_run_id: retry_run_id
             })

    completed = Review.get_review_case!(updated.id, actor: actor)

    assert [%{status: :succeeded, output: %{"text" => "corrected extraction"}}] =
             completed.source_version.processing_runs

    unchanged_version = Ingestion.get_source_version!(context.version.id)
    assert unchanged_version.sha256 == original_version.sha256
    assert unchanged_version.object_key == original_version.object_key
    assert BrusselsWtf.Archive.get(unchanged_version.object_key) == {:ok, original_bytes}
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
      %{review_case: review_case} = build_case!(generation: Atom.to_string(disposition))

      updated =
        apply(Review, operation, [
          review_case,
          %{note: "reviewed", details: %{"reason" => "fixture"}},
          [actor: actor]
        ])

      detail = Review.get_review_case!(updated.id, actor: actor)

      assert updated.disposition == disposition
      assert [%{effect: ^effect, disposition: ^disposition, actor_id: "rico"}] = detail.actions

      case effect do
        :domain_revision -> assert [%{actor_id: "rico", note: "reviewed"}] = detail.revisions
        :exclusion -> assert [%{actor_id: "rico", reason: "reviewed"}] = detail.exclusions
      end
    end
  end

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

    %{commune: commune, record: record, version: version, review_case: review_case, bytes: bytes}
  end
end
