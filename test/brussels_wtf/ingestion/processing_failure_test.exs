defmodule BrusselsWtf.Ingestion.ProcessingFailureTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Review
  alias BrusselsWtf.Review.Actor
  alias BrusselsWtf.Workers.ExtractSource

  setup do
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-08-20 12:00:00Z])

    commune =
      Ingestion.create_commune!(%{
        slug: "ixelles",
        name: "Ixelles",
        index_url: "https://example.test/index"
      })

    bytes = "%PDF low quality"
    {:ok, archived} = BrusselsWtf.Archive.store(bytes)

    record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: "https://example.test/low-quality.pdf",
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
        first_retrieved_at: ~U[2026-08-20 12:00:00Z]
      })

    BrusselsWtf.Processors.Stub.put(version.sha256, %{
      extract: {:error, :repeated_quality_failure}
    })

    {:ok, version: version, actor: %Actor{id: "rico", role: :reviewer}}
  end

  test "a deterministic quality failure stops immediately and converges on one case", %{
    version: version,
    actor: actor
  } do
    job = build_job(ExtractSource, %{source_version_id: version.id}, attempt: 1)
    assert :ok = perform_job(job)
    assert :ok = perform_job(job)

    assert [review_case] = Review.list_review_cases!(%{kind: :extraction}, actor: actor)
    assert review_case.source_version_id == version.id

    assert review_case.processing_generation ==
             "extraction:#{version.id}:repeated_quality_failure"

    assert review_case.summary =~ "quality"

    assert [%{status: :failed, output: %{"classification" => "repeated_quality_failure"}}] =
             version.id
             |> Ingestion.get_source_version!()
             |> Ash.load!(:processing_runs)
             |> Map.fetch!(:processing_runs)
  end
end
