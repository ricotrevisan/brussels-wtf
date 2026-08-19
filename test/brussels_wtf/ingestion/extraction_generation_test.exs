defmodule BrusselsWtf.Ingestion.ExtractionGenerationTest do
  use BrusselsWtf.DataCase, async: false

  alias BrusselsWtf.Ingestion

  defmodule RevisedPdfProcessor do
    @behaviour BrusselsWtf.PDF.Processor

    @impl true
    defdelegate native(meta, bytes), to: BrusselsWtf.PDF.Stub

    @impl true
    defdelegate ocr(meta, bytes, pages), to: BrusselsWtf.PDF.Stub

    @impl true
    def metadata do
      BrusselsWtf.PDF.Stub.metadata()
      |> Map.put(:native_processor_version, "fixture-poppler-24.03")
      |> Map.put(:config_hash, "sha256:fixture-pdf-quality-v2")
    end
  end

  setup do
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-08-20 12:00:00Z])

    commune =
      Ingestion.create_commune!(%{
        slug: "uccle",
        name: "Uccle",
        index_url: "https://example.test/uccle"
      })

    bytes = "%PDF shared born-digital bytes"
    {:ok, archived} = BrusselsWtf.Archive.store(bytes)

    versions =
      for suffix <- ["agenda", "project"] do
        record =
          Ingestion.upsert_source_record!(%{
            commune_id: commune.id,
            origin_url: "https://example.test/uccle/#{suffix}.pdf",
            role: :agenda,
            original_language: :bilingual
          })

        Ingestion.upsert_source_version!(%{
          source_record_id: record.id,
          sha256: archived.sha256,
          byte_size: byte_size(bytes),
          media_type: "application/pdf",
          object_key: archived.object_key,
          first_retrieved_at: BrusselsWtf.Clock.utc_now()
        })
      end

    BrusselsWtf.Processors.Stub.put(archived.sha256, %{
      extract: %{
        "text" => "Conseil communal Gemeenteraad proposition publique officieel voorstel",
        "quality" => "accepted"
      }
    })

    {:ok, versions: versions}
  end

  test "one content-addressed artifact can retain provenance links to both processing generations",
       %{
         versions: [first, second]
       } do
    assert :ok = BrusselsWtf.Ingestion.Pipeline.extract(first.id)
    assert :ok = BrusselsWtf.Ingestion.Pipeline.extract(second.id)

    [first_run] =
      first.id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)

    [second_run] =
      second.id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)

    first_run = Ash.load!(first_run, :derived_artifacts)
    second_run = Ash.load!(second_run, :derived_artifacts)

    assert [first_artifact] = first_run.derived_artifacts
    assert [second_artifact] = second_run.derived_artifacts
    assert first_artifact.id == second_artifact.id
    assert first_artifact.output_sha256 == second_artifact.output_sha256
    assert first_run.id != second_run.id
  end

  test "same-config generations retain distinct output bytes", %{versions: [version, _other]} do
    runs =
      for generation <- ["review:first", "review:second"] do
        Ingestion.record_processing_run!(%{
          source_version_id: version.id,
          generation_key: generation,
          processor_name: "same-config-processor",
          processor_version: "1",
          config_hash: "sha256:same-config",
          status: :succeeded
        })
      end

    artifacts =
      Enum.zip(runs, ["first output", "second output"])
      |> Enum.map(fn {run, output} ->
        {:ok, archived} = BrusselsWtf.Archive.store(output, :derived)

        artifact =
          Ingestion.upsert_derived_artifact!(%{
            source_version_id: version.id,
            processing_run_id: run.id,
            input_sha256: version.sha256,
            output_sha256: archived.sha256,
            processor_name: run.processor_name,
            processor_version: run.processor_version,
            config_hash: run.config_hash,
            output_kind: "native-text",
            object_key: archived.object_key,
            media_type: "text/plain",
            byte_size: byte_size(output),
            quality_measurements: %{"accepted" => true}
          })

        Ingestion.link_processing_run_artifact!(%{
          processing_run_id: run.id,
          derived_artifact_id: artifact.id,
          role: :native_output
        })

        artifact
      end)

    assert [first, second] = artifacts
    assert first.id != second.id
    assert first.output_sha256 != second.output_sha256
    assert BrusselsWtf.Archive.get(first.object_key) == {:ok, "first output"}
    assert BrusselsWtf.Archive.get(second.object_key) == {:ok, "second output"}
  end

  test "a changed processor configuration appends a new generation without rewriting the old one",
       %{
         versions: [version, _other]
       } do
    assert :ok = BrusselsWtf.Ingestion.Pipeline.extract(version.id)

    [first] =
      version.id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)

    [first_artifact] = Ash.load!(first, :derived_artifacts).derived_artifacts

    previous = Application.fetch_env!(:brussels_wtf, :pdf_processor)
    Application.put_env(:brussels_wtf, :pdf_processor, RevisedPdfProcessor)
    on_exit(fn -> Application.put_env(:brussels_wtf, :pdf_processor, previous) end)

    assert :ok = BrusselsWtf.Ingestion.Pipeline.extract(version.id)

    runs =
      version.id
      |> Ingestion.get_source_version!()
      |> Ash.load!(:processing_runs)
      |> Map.fetch!(:processing_runs)

    unchanged = Enum.find(runs, &(&1.processor_version == "fixture-poppler-24.02"))
    revised = Enum.find(runs, &(&1.processor_version == "fixture-poppler-24.03"))
    assert length(runs) == 2
    assert unchanged.id == first.id
    assert unchanged.processor_version == "fixture-poppler-24.02"
    assert revised.processor_version == "fixture-poppler-24.03"
    assert unchanged.config_hash != revised.config_hash

    [revised_artifact] = Ash.load!(revised, :derived_artifacts).derived_artifacts
    assert revised_artifact.id != first_artifact.id
    assert revised_artifact.output_sha256 == first_artifact.output_sha256
    assert {:ok, _old_bytes} = BrusselsWtf.Archive.get(first_artifact.object_key)
  end
end
