defmodule BrusselsWtf.Ingestion.NormalizationReviewTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Ingestion

  setup do
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-08-21 02:30:00Z])

    commune =
      Ingestion.create_commune!(%{
        slug: "forest",
        name: "Forest",
        index_url: "https://example.test/forest"
      })

    bytes = "%PDF recorded born-digital normalization review fixture"
    {:ok, archived} = BrusselsWtf.Archive.store(bytes)

    record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: "https://example.test/forest/agenda.pdf",
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
        first_retrieved_at: BrusselsWtf.Clock.utc_now()
      })

    BrusselsWtf.Processors.Stub.put(version.sha256, %{
      extract: %{
        "text" =>
          "Conseil communal de Forest ordre du jour public avec contenu officiel suffisant",
        "quality" => "accepted"
      },
      normalize: {:error, :processor_unimplemented}
    })

    assert :ok = Ingestion.Pipeline.extract(version.id)

    [run] =
      version.id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)

    {:ok, version: version, record: record, run: run}
  end

  test "an unavailable normalizer creates one actionable case without retrying forever", %{
    version: version,
    record: record,
    run: run
  } do
    assert :ok =
             perform_job(BrusselsWtf.Workers.NormalizeSource, %{
               processing_run_id: run.id,
               locator_url: "https://example.test/forest/agenda.pdf"
             })

    assert :ok =
             Ingestion.Pipeline.normalize(
               run.id,
               "https://example.test/forest/agenda.pdf"
             )

    assert [review_case] =
             BrusselsWtf.Review.list_review_cases!(
               %{kind: :normalization, status: :open},
               authorize?: false
             )

    assert review_case.commune_id == record.commune_id
    assert review_case.affected_record_id == version.id
    assert review_case.affected_record_type == "source_version"
    assert review_case.source_record_id == record.id
    assert review_case.source_version_id == version.id
    assert review_case.processing_generation == "normalization:#{run.id}"
    assert review_case.summary == "Automatic normalization is unavailable and requires review"

    assert review_case.diagnostics == %{
             "classification" => "processor_unavailable",
             "detail" => "No production normalizer is configured"
           }

    assert review_case.related_evidence == %{
             "citation_url" => "https://example.test/forest/agenda.pdf",
             "processing_run_id" => run.id
           }

    refute_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)
  end

  test "normalization ambiguity preserves candidates privately and does not publish", %{
    version: version,
    run: run
  } do
    candidates = %{
      "meeting_identifier" => "forest-2026-08-18",
      "possible_item_numbers" => ["12", "12bis"],
      "reason" => "The supplement does not carry an authoritative continuity identifier"
    }

    BrusselsWtf.Processors.Stub.put(version.sha256, %{
      normalize: {:error, {:normalization_ambiguity, candidates}}
    })

    assert :ok =
             perform_job(BrusselsWtf.Workers.NormalizeSource, %{
               processing_run_id: run.id,
               locator_url: "https://example.test/forest/agenda.pdf"
             })

    assert [review_case] =
             BrusselsWtf.Review.list_review_cases!(
               %{kind: :normalization, status: :open},
               authorize?: false
             )

    assert review_case.summary == "Normalized item continuity is ambiguous and requires review"
    assert review_case.normalized_content == candidates

    assert review_case.diagnostics == %{
             "classification" => "normalization_ambiguity",
             "detail" => "The processor returned competing normalized candidates"
           }

    refute_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)
  end

  test "a repeated normalization failure becomes one review case on the final attempt", %{
    version: version,
    run: run
  } do
    BrusselsWtf.Processors.Stub.put(version.sha256, %{
      normalize: {:error, :temporary_unavailable}
    })

    assert {:error, :temporary_unavailable} =
             perform_job(
               BrusselsWtf.Workers.NormalizeSource,
               %{
                 processing_run_id: run.id,
                 locator_url: "https://example.test/forest/agenda.pdf"
               },
               attempt: 1
             )

    assert [] =
             BrusselsWtf.Review.list_review_cases!(
               %{kind: :normalization, status: :open},
               authorize?: false
             )

    assert :ok =
             perform_job(
               BrusselsWtf.Workers.NormalizeSource,
               %{
                 processing_run_id: run.id,
                 locator_url: "https://example.test/forest/agenda.pdf"
               },
               attempt: 3
             )

    assert [review_case] =
             BrusselsWtf.Review.list_review_cases!(
               %{kind: :normalization, status: :open},
               authorize?: false
             )

    assert review_case.summary == "Automatic normalization failed repeatedly and requires review"

    assert review_case.diagnostics == %{
             "classification" => "processor_failure",
             "detail" => "The normalizer failed after three attempts"
           }

    refute_enqueued(worker: BrusselsWtf.Workers.PublishMeeting)
  end
end
