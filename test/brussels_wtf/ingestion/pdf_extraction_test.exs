defmodule BrusselsWtf.Ingestion.PdfExtractionTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Ingestion

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

    bytes = "%PDF recorded born-digital fixture"
    {:ok, archived} = BrusselsWtf.Archive.store(bytes)

    record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: "https://example.test/agenda.pdf",
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
        "text" => "Conseil communal Gemeenteraad proposition publique officieel voorstel",
        "page_count" => 1,
        "quality" => "accepted"
      },
      normalize: %{}
    })

    {:ok, version: version}
  end

  test "born-digital PDF extraction records page quality, tool provenance, and immutable text", %{
    version: version
  } do
    assert :ok = BrusselsWtf.Ingestion.Pipeline.extract(version.id)

    loaded =
      Ingestion.get_source_version!(version.id)
      |> Ash.load!([:processing_runs, :derived_artifacts])

    assert [run] = loaded.processing_runs
    assert Map.fetch!(run, :processor_role) == :native_extraction
    assert run.processor_name == "poppler-native-text"
    assert run.processor_version == "fixture-poppler-24.02"
    assert run.status == :succeeded
    assert [%{attempt: 1, status: :succeeded}] = Ash.load!(run, :attempts).attempts
    assert Map.fetch!(run, :failure_classification) == nil
    assert Map.fetch!(run, :duration_ms) >= 0

    assert %{"pdfinfo" => "fixture-poppler-24.02", "pdftotext" => "fixture-poppler-24.02"} =
             Map.fetch!(run, :tool_versions)

    assert %{
             "page_count" => 1,
             "pages" => [
               %{
                 "page" => 1,
                 "decision" => "accepted",
                 "measurements" => %{
                   "characters" => characters,
                   "words" => words,
                   "alphanumeric_ratio" => ratio
                 }
               }
             ]
           } = Map.fetch!(run, :quality_measurements)

    assert characters > 40
    assert words >= 6
    assert ratio > 0.5

    assert [artifact] = loaded.derived_artifacts
    assert artifact.processing_run_id == run.id
    assert artifact.input_sha256 == version.sha256
    assert artifact.output_kind == "native-text"
    assert artifact.media_type == "text/plain; charset=utf-8"
    assert String.starts_with?(artifact.object_key, "derived/sha256/")
    assert {:ok, text} = BrusselsWtf.Archive.get(artifact.object_key)
    assert text =~ "Gemeenteraad"
    assert BrusselsWtf.Digest.sha256(text) == artifact.output_sha256

    assert_enqueued(
      worker: BrusselsWtf.Workers.NormalizeSource,
      args: %{processing_run_id: run.id}
    )
  end

  test "failed attempts preserve safe nested command outcomes", %{version: version} do
    BrusselsWtf.Processors.Stub.put(version.sha256, %{
      extract: {:error, {:invalid_pdf, {:pdfinfo_exit, 42}}}
    })

    assert {:error, {:invalid_pdf, {:pdfinfo_exit, 42}}} =
             BrusselsWtf.Ingestion.Pipeline.extract(version.id, 1)

    [run] =
      version.id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)

    assert [%{diagnostics: diagnostics}] = Ash.load!(run, :attempts).attempts

    assert diagnostics == %{
             "classification" => "invalid_content",
             "detail" => %{
               "kind" => "invalid_pdf",
               "outcome" => "pdfinfo_exit",
               "exit_status" => 42
             }
           }
  end

  test "successful generation finalization rolls back as one database unit", %{version: version} do
    metadata = BrusselsWtf.PDF.Processor.metadata()

    run =
      Ingestion.create_review_processing_run!(%{
        source_version_id: version.id,
        processor_name: metadata.native_processor_name,
        processor_version: metadata.native_processor_version,
        config_hash: metadata.config_hash,
        status: :queued,
        output: %{"review_case_id" => Ecto.UUID.generate()}
      })

    assert_raise Ash.Error.Invalid, fn ->
      BrusselsWtf.Ingestion.Pipeline.retry_extraction(run.id, 1)
    end

    rolled_back =
      Ingestion.get_processing_run!(run.id) |> Ash.load!([:attempts, :derived_artifacts])

    assert rolled_back.status == :queued
    assert rolled_back.attempts == []
    assert rolled_back.derived_artifacts == []
    refute_enqueued(worker: BrusselsWtf.Workers.NormalizeSource)
  end

  test "a transient native attempt can succeed without changing the processing identity", %{
    version: version
  } do
    BrusselsWtf.Processors.Stub.put(version.sha256, %{extract: {:error, :temporary_unavailable}})

    handler_id = "native-retry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:brussels_wtf, :ingestion, :processing, :retry],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, :temporary_unavailable} =
             perform_job(
               BrusselsWtf.Workers.ExtractSource,
               %{source_version_id: version.id},
               attempt: 1
             )

    assert_receive {:telemetry, [:brussels_wtf, :ingestion, :processing, :retry], %{count: 1},
                    %{processing_run_id: run_id, processor_role: :native_extraction, attempt: 1}}

    assert is_binary(run_id)

    BrusselsWtf.Processors.Stub.put(version.sha256, %{
      extract: %{
        "text" =>
          "Conseil communal Gemeenteraad corrected official proposal with sufficient public text"
      }
    })

    assert :ok =
             perform_job(
               BrusselsWtf.Workers.ExtractSource,
               %{source_version_id: version.id},
               attempt: 2
             )

    [run] =
      version.id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)

    assert run.status == :succeeded

    assert [%{attempt: 1, status: :failed}, %{attempt: 2, status: :succeeded}] =
             Ash.load!(run, :attempts).attempts |> Enum.sort_by(& &1.attempt)
  end
end
