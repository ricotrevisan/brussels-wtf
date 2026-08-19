defmodule BrusselsWtf.Ingestion.OcrFallbackTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Ingestion

  setup do
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-08-20 12:00:00Z])

    commune =
      Ingestion.create_commune!(%{
        slug: "forest",
        name: "Forest",
        index_url: "https://example.test/forest"
      })

    bytes = "%PDF recorded partial scan"
    {:ok, archived} = BrusselsWtf.Archive.store(bytes)

    record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: "https://example.test/forest/agenda.pdf",
        role: :agenda,
        original_language: :bilingual
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
        "text" => "native page one\f\fnative page three",
        "page_texts" => [
          "Conseil communal proposition avec suffisamment de texte officiel page un",
          "",
          "Gemeenteraad officieel voorstel met voldoende digitale tekst pagina drie"
        ]
      },
      ocr: %{
        "page_texts" => [
          "Conseil communal proposition avec suffisamment de texte officiel page un",
          "Page deux numérisée — proposition officielle en français en Nederlands",
          "Gemeenteraad officieel voorstel met voldoende digitale tekst pagina drie"
        ],
        "searchable_pdf" => "%PDF searchable OCR fixture"
      }
    })

    {:ok, version: version}
  end

  test "only rejected native pages route through bilingual OCR and both generations remain immutable",
       %{
         version: version
       } do
    assert :ok = BrusselsWtf.Ingestion.Pipeline.extract(version.id)

    version =
      Ingestion.get_source_version!(version.id)
      |> Ash.load!([:processing_runs, :derived_artifacts])

    native = Enum.find(version.processing_runs, &(&1.processor_role == :native_extraction))
    ocr = Enum.find(version.processing_runs, &(&1.processor_role == :ocr))
    assert native.status == :succeeded
    assert native.quality_measurements["rejected_pages"] == [2]
    assert ocr.processor_role == :ocr
    assert ocr.status == :queued
    assert ocr.inputs["pages"] == [2]
    assert ocr.inputs["languages"] == "fra+nld"

    assert_enqueued(worker: BrusselsWtf.Workers.OCRSource, args: %{processing_run_id: ocr.id})
    refute_enqueued(worker: BrusselsWtf.Workers.NormalizeSource)

    assert_raise RuntimeError, "processing run has no accepted extraction quality decision", fn ->
      BrusselsWtf.Ingestion.Pipeline.normalize(
        native.id,
        "https://example.test/forest/agenda.pdf"
      )
    end

    assert :ok = perform_job(BrusselsWtf.Workers.OCRSource, %{processing_run_id: ocr.id})

    completed = Ingestion.get_processing_run!(ocr.id)
    assert completed.status == :succeeded
    assert completed.quality_measurements["accepted"]

    artifacts =
      Ingestion.get_source_version!(version.id)
      |> Ash.load!(:derived_artifacts)
      |> Map.fetch!(:derived_artifacts)

    assert MapSet.new(Enum.map(artifacts, & &1.output_kind)) ==
             MapSet.new(["native-text", "ocr-pdf", "ocr-text"])

    native_artifact = Enum.find(artifacts, &(&1.output_kind == "native-text"))
    ocr_pdf = Enum.find(artifacts, &(&1.output_kind == "ocr-pdf"))
    ocr_text = Enum.find(artifacts, &(&1.output_kind == "ocr-text"))
    assert String.starts_with?(ocr_pdf.object_key, "derived/sha256/")
    assert native_artifact.processing_run_id == native.id
    assert ocr_text.processing_run_id == ocr.id
    assert {:ok, final_text} = BrusselsWtf.Archive.get(ocr_text.object_key)
    assert String.split(final_text, "\f") |> Enum.at(1) =~ "numérisée"

    assert_enqueued(
      worker: BrusselsWtf.Workers.NormalizeSource,
      args: %{processing_run_id: ocr.id}
    )
  end

  test "a hard OCR limit fails the generation and converges on one review case", %{
    version: version
  } do
    {:ok, outputs} = BrusselsWtf.Processors.Stub.pdf_fixture(version.sha256, :extract)

    BrusselsWtf.Processors.Stub.put(version.sha256, %{
      extract: outputs,
      ocr: {:error, {:ocr_limit, :wall_time}}
    })

    assert :ok = BrusselsWtf.Ingestion.Pipeline.extract(version.id)

    [ocr] =
      version.id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.filter(&(&1.processor_role == :ocr))

    assert :ok = perform_job(BrusselsWtf.Workers.OCRSource, %{processing_run_id: ocr.id})
    failed = Ingestion.get_processing_run!(ocr.id)
    assert failed.status == :failed
    assert failed.failure_classification == "resource_limit"

    assert [%{attempt: 1, status: :failed, failure_classification: "resource_limit"}] =
             Ash.load!(failed, :attempts).attempts

    cases =
      BrusselsWtf.Review.list_review_cases!(%{}, authorize?: false)
      |> Enum.filter(&(&1.affected_record_id == version.id))

    assert [review_case] = cases
    assert review_case.related_evidence["processing_run_id"] == ocr.id
    assert review_case.diagnostics["classification"] == "resource_limit"

    assert get_in(review_case.diagnostics, ["processing_run", "failure_classification"]) ==
             "resource_limit"

    assert [%{"attempt" => 1, "failure_classification" => "resource_limit"}] =
             get_in(review_case.diagnostics, ["processing_run", "attempts"])

    BrusselsWtf.Ingestion.ExtractionReview.open_for_version(version.id, :resource_limit, ocr.id)

    cases =
      BrusselsWtf.Review.list_review_cases!(%{}, authorize?: false)
      |> Enum.filter(&(&1.affected_record_id == version.id))

    assert length(cases) == 1
  end

  test "rejected OCR outputs remain immutable review evidence", %{version: version} do
    {:ok, native} = BrusselsWtf.Processors.Stub.pdf_fixture(version.sha256, :extract)

    BrusselsWtf.Processors.Stub.put(version.sha256, %{
      extract: native,
      ocr: %{
        "page_texts" => ["", "", ""],
        "searchable_pdf" => "%PDF rejected searchable fixture"
      }
    })

    assert :ok = BrusselsWtf.Ingestion.Pipeline.extract(version.id)

    [ocr] =
      version.id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.filter(&(&1.processor_role == :ocr))

    assert :ok = perform_job(BrusselsWtf.Workers.OCRSource, %{processing_run_id: ocr.id})

    failed = Ingestion.get_processing_run!(ocr.id) |> Ash.load!(:derived_artifacts)
    assert failed.status == :failed
    assert failed.failure_classification == "repeated_quality_failure"

    assert MapSet.new(Enum.map(failed.derived_artifacts, & &1.output_kind)) ==
             MapSet.new(["ocr-pdf", "ocr-text"])

    assert Enum.all?(failed.derived_artifacts, fn artifact ->
             artifact.quality_measurements["accepted"] == false and
               String.starts_with?(artifact.object_key, "derived/sha256/")
           end)

    [review_case] =
      BrusselsWtf.Review.list_review_cases!(%{kind: :extraction, status: :open},
        authorize?: false
      )

    assert get_in(review_case.diagnostics, ["processing_run", "quality_measurements", "accepted"]) ==
             false

    assert review_case.diagnostics
           |> get_in(["processing_run", "artifacts"])
           |> Enum.map(& &1["output_kind"])
           |> MapSet.new() == MapSet.new(["ocr-pdf", "ocr-text"])

    refute_enqueued(worker: BrusselsWtf.Workers.NormalizeSource)
  end

  test "a transient OCR attempt can complete the queued generation on retry", %{version: version} do
    assert :ok = BrusselsWtf.Ingestion.Pipeline.extract(version.id)

    [run] =
      version.id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)
      |> Enum.filter(&(&1.processor_role == :ocr))

    {:ok, native} = BrusselsWtf.Processors.Stub.pdf_fixture(version.sha256, :extract)

    BrusselsWtf.Processors.Stub.put(version.sha256, %{
      extract: native,
      ocr: {:error, :temporary_ocr_failure}
    })

    assert {:error, :temporary_ocr_failure} = BrusselsWtf.Ingestion.Pipeline.ocr(run.id, 1)

    BrusselsWtf.Processors.Stub.put(version.sha256, %{
      extract: native,
      ocr: %{
        "page_texts" => [
          "Conseil communal proposition avec suffisamment de texte officiel page un",
          "Page deux numérisée proposition officielle français Nederlands complète",
          "Gemeenteraad officieel voorstel met voldoende digitale tekst pagina drie"
        ],
        "searchable_pdf" => "%PDF retry searchable fixture"
      }
    })

    assert :ok = BrusselsWtf.Ingestion.Pipeline.ocr(run.id, 2)
    completed = Ingestion.get_processing_run!(run.id) |> Ash.load!(:attempts)
    assert completed.status == :succeeded

    assert Enum.map(Enum.sort_by(completed.attempts, & &1.attempt), &{&1.attempt, &1.status}) == [
             {1, :failed},
             {2, :succeeded}
           ]
  end
end
