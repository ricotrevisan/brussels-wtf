defmodule BrusselsWtf.Ingestion.LargeSupportingDocumentTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.{Archive, Ingestion, Review}
  alias BrusselsWtf.Ingestion.Pipeline
  @actor %Review.Actor{id: "rico", role: :reviewer}

  setup do
    BrusselsWtf.HTTP.Stub.reset()
    Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-10-10 12:00:00Z])
    temporary_root = Path.join(System.tmp_dir!(), "brussels-test-source-#{Ecto.UUID.generate()}")
    File.mkdir!(temporary_root)
    previous_tmpdir = System.get_env("TMPDIR")
    System.put_env("TMPDIR", temporary_root)

    on_exit(fn ->
      if previous_tmpdir,
        do: System.put_env("TMPDIR", previous_tmpdir),
        else: System.delete_env("TMPDIR")

      File.rm_rf!(temporary_root)
    end)

    limits = Application.fetch_env!(:brussels_wtf, :pdf_limits)
    Application.put_env(:brussels_wtf, :pdf_limits, %{limits | max_input_bytes: 16})
    on_exit(fn -> Application.put_env(:brussels_wtf, :pdf_limits, limits) end)

    commune =
      Ingestion.create_commune!(%{
        slug: "city-of-brussels",
        name: "Brussels",
        index_url: "https://example.test/index"
      })

    locator =
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: "https://example.test/support.pdf",
        parent_index_url: commune.index_url,
        meeting_identifier: "2026-10-15",
        scheduled_on: ~D[2026-10-15],
        role: :supporting_document,
        language: :fr,
        discovered_at: ~U[2026-10-10 11:00:00Z]
      })

    %{commune: commune, locator: locator, temporary_root: temporary_root}
  end

  test "large supporting bytes are archived successfully without automatic extraction", %{
    commune: commune,
    locator: locator,
    temporary_root: temporary_root
  } do
    bytes = "%PDF-1.7 " <> String.duplicate("x", 32)

    BrusselsWtf.HTTP.Stub.put(locator.url, %{
      status: 200,
      body: bytes,
      headers: %{"etag" => ["large-a"]}
    })

    run = Ingestion.request_scheduled_poll!(commune.slug)
    assert :ok = Pipeline.retrieve(locator.id, run.id, run.check_key)
    history = Ingestion.source_history!(commune.id, locator.url)
    assert [version] = history.versions
    assert version.byte_size == byte_size(bytes)
    assert version.sha256 == BrusselsWtf.Digest.sha256(bytes)
    assert {:ok, ^bytes} = Archive.get(version.object_key)
    assert [%{status: :success, source_version_id: version_id}] = history.observations
    assert version_id == version.id
    refute_enqueued(worker: BrusselsWtf.Workers.ExtractSource)
    refute_enqueued(worker: BrusselsWtf.Workers.OCRSource)
    assert [review] = Review.list_review_cases!(%{kind: :extraction}, actor: @actor)
    assert review.source_version_id == version.id
    assert review.diagnostics["classification"] == "resource_limit"

    BrusselsWtf.Clock.Controlled.set(~U[2026-10-10 12:00:01Z])
    again = Ingestion.request_poll_now!(%{type: :locator, id: locator.id}, actor: @actor)
    assert :ok = Pipeline.retrieve(locator.id, again.id, again.check_key)
    assert [_] = Review.list_review_cases!(%{kind: :extraction}, actor: @actor)
    assert [_] = Ingestion.source_history!(commune.id, locator.url).versions

    BrusselsWtf.HTTP.Stub.put(locator.url, %{status: 304})
    unchanged = Ingestion.request_poll_now!(%{type: :locator, id: locator.id}, actor: @actor)
    assert :ok = Pipeline.retrieve(locator.id, unchanged.id, unchanged.check_key)

    assert List.last(Ingestion.source_history!(commune.id, locator.url).observations).status ==
             :unchanged

    assert List.last(BrusselsWtf.HTTP.Stub.requests(locator.url))[:headers]["if-none-match"] == [
             "large-a"
           ]

    changed_bytes = bytes <> "changed"
    BrusselsWtf.Clock.Controlled.set(~U[2026-10-10 12:00:02Z])
    BrusselsWtf.HTTP.Stub.put(locator.url, %{status: 200, body: changed_bytes})
    changed = Ingestion.request_poll_now!(%{type: :locator, id: locator.id}, actor: @actor)
    assert :ok = Pipeline.retrieve(locator.id, changed.id, changed.check_key)
    assert length(Ingestion.source_history!(commune.id, locator.url).versions) == 2
    assert length(Review.list_review_cases!(%{kind: :extraction}, actor: @actor)) == 2
    assert Ingestion.get_poll_run!(run.id).status != :failed
    assert File.ls!(temporary_root) == []
  end

  test "small supporting documents still enqueue native-first extraction", %{
    commune: commune,
    locator: locator
  } do
    BrusselsWtf.HTTP.Stub.put(locator.url, %{status: 200, body: "%PDF-1.7 small"})
    run = Ingestion.request_poll_now!(%{type: :locator, id: locator.id}, actor: @actor)
    assert :ok = Pipeline.retrieve(locator.id, run.id, run.check_key)
    [version] = Ingestion.source_history!(commune.id, locator.url).versions

    assert_enqueued(
      worker: BrusselsWtf.Workers.ExtractSource,
      args: %{source_version_id: version.id}
    )

    assert Review.list_review_cases!(%{kind: :extraction}, actor: @actor) == []
  end

  test "failed downloads retain observations and remove temporary files", %{
    locator: locator,
    temporary_root: temporary_root
  } do
    BrusselsWtf.HTTP.Stub.put_error(locator.url, %Req.TransportError{reason: :timeout})
    run = Ingestion.request_poll_now!(%{type: :locator, id: locator.id}, actor: @actor)
    assert {:retry, _delay} = Pipeline.retrieve(locator.id, run.id, run.check_key)
    assert File.ls!(temporary_root) == []

    assert [%{status: :failure, source_version_id: nil}] =
             Ingestion.list_observations!(locator.id)
  end

  test "queued native extraction rejects large metadata before fetching archive bytes", %{
    commune: commune,
    locator: locator
  } do
    record =
      Ingestion.upsert_source_record!(%{
        commune_id: commune.id,
        origin_url: locator.url,
        role: :supporting_document,
        original_language: :fr
      })

    version =
      Ingestion.upsert_source_version!(%{
        source_record_id: record.id,
        sha256: String.duplicate("a", 64),
        byte_size: 32,
        media_type: "application/pdf",
        object_key: "raw/sha256/aa/" <> String.duplicate("a", 64),
        first_retrieved_at: ~U[2026-10-10 12:00:00Z]
      })

    # No archive object exists: a resource-limit result proves rejection precedes archive access.
    assert {:error, {:oversized_pdf, %{byte_size: 32, limit: 16}}} = Pipeline.extract(version.id)
    metadata = BrusselsWtf.PDF.Processor.metadata()

    run =
      Ingestion.record_processing_run!(%{
        source_version_id: version.id,
        processor_role: :ocr,
        processor_name: metadata.ocr_processor_name,
        processor_version: metadata.ocr_processor_version,
        config_hash: metadata.config_hash,
        inputs: %{"pages" => [1]},
        status: :queued
      })

    assert {:error, {:oversized_pdf, %{byte_size: 32, limit: 16}}} = Pipeline.ocr(run.id)

    refute_enqueued(worker: BrusselsWtf.Workers.OCRSource)
  end
end
