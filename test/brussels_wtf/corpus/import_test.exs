defmodule BrusselsWtf.Corpus.ImportTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.{Archive, Council, HTTP}
  alias BrusselsWtf.Corpus.{Import, Manifest}
  alias BrusselsWtf.Review.Actor

  setup do
    HTTP.Stub.reset()
    BrusselsWtf.Archive.Memory.reset()
    previous_loader = Application.get_env(:brussels_wtf, :corpus_source_loader)

    on_exit(fn ->
      if previous_loader,
        do: Application.put_env(:brussels_wtf, :corpus_source_loader, previous_loader),
        else: Application.delete_env(:brussels_wtf, :corpus_source_loader)
    end)

    BrusselsWtf.Clock.Controlled.set(~U[2026-08-21 14:00:00Z])
    :ok
  end

  test "a reviewer seals the exact eight-meeting, nine-document manifest before work is queued" do
    keys = Enum.map(Manifest.load!()["meetings"], & &1["key"])
    batch = Import.request!(keys, %Actor{id: "rico", role: :reviewer})

    assert batch.status == :importing
    assert batch.meeting_keys == keys
    assert batch.expected_documents == 9
    assert batch.expected_bytes > 0
    assert batch.manifest_sha256 == Manifest.digest()
    assert batch.metrics["meetings_selected"] == 8
    assert batch.metrics["documents_expected"] == 9

    jobs = all_enqueued(worker: BrusselsWtf.Workers.ImportCorpusSource)
    assert length(jobs) == 9
  end

  test "authorization and allowlist bounds fail before a batch or job exists" do
    assert_raise ArgumentError, ~r/authenticated reviewer/, fn ->
      Import.request!(["ixelles-268"], %Actor{id: "system", role: :system})
    end

    assert_raise ArgumentError, ~r/sealed eight-meeting allowlist/, fn ->
      Import.request!(["unknown-meeting"], %Actor{id: "rico", role: :reviewer})
    end

    assert_raise ArgumentError, ~r/sealed eight-meeting allowlist/, fn ->
      Import.request!(["ixelles-268", "ixelles-268"], %Actor{id: "rico", role: :reviewer})
    end

    assert Council.list_corpus_import_batches!() == []
    refute_enqueued worker: BrusselsWtf.Workers.ImportCorpusSource
  end

  test "matching official bytes are archived and only then enter backfill extraction" do
    meeting = Manifest.meeting!("ixelles-268")
    [source] = meeting["sources"]
    bytes = File.read!("test/support/pdf_calibration/ixelles.pdf")
    assert BrusselsWtf.Digest.sha256(bytes) == source["sha256"]

    batch = Import.request!([meeting["key"]], %Actor{id: "rico", role: :reviewer})

    assert :ok =
             perform_job(BrusselsWtf.Workers.ImportCorpusSource, %{
               corpus_import_batch_id: batch.id,
               meeting_key: meeting["key"],
               source_name: source["name"]
             })

    imported = Council.get_corpus_import_batch!(batch.id)
    assert imported.status == :normalizing
    assert length(imported.meeting_ids) == 1
    assert [source_version_id] = imported.source_version_ids

    version = BrusselsWtf.Ingestion.get_source_version!(source_version_id)
    assert version.sha256 == source["sha256"]
    assert version.byte_size == source["byte_size"]
    assert {:ok, ^bytes} = Archive.get(version.object_key)
    {:ok, captured_at, 0} = DateTime.from_iso8601(source["captured_at"])
    assert DateTime.compare(version.first_retrieved_at, captured_at) == :eq

    [locator] =
      BrusselsWtf.Ingestion.SourceLocator
      |> Ash.read!(domain: BrusselsWtf.Ingestion)

    assert locator.url == source["url"]
    assert locator.parent_index_url == source["parent_index_url"]
    assert locator.meeting_identifier == meeting["municipal_identifier"]
    assert DateTime.compare(locator.discovered_at, captured_at) == :eq

    [observation] =
      BrusselsWtf.Ingestion.RetrievalObservation
      |> Ash.read!(domain: BrusselsWtf.Ingestion)
      |> Ash.load!(:poll_run)

    assert observation.source_locator_id == locator.id
    assert observation.source_version_id == version.id
    assert observation.status == :success
    assert observation.http_status == nil
    assert observation.final_url == nil
    assert observation.response_headers == %{}
    assert observation.poll_run.requester_id == "rico"
    assert observation.check_key =~ batch.id

    assert_enqueued worker: BrusselsWtf.Workers.ExtractSource,
                    args: %{source_version_id: version.id, generation_kind: "backfill"}

    assert HTTP.Stub.requests(source["url"]) == []
  end

  test "changed bytes are retained for audit but block extraction and open one acquisition case" do
    meeting = Manifest.meeting!("ixelles-268")
    [source] = meeting["sources"]
    changed = "%PDF-1.7 changed municipal bytes"

    Application.put_env(:brussels_wtf, :corpus_source_loader, fn _path -> {:ok, changed} end)

    batch = Import.request!([meeting["key"]], %Actor{id: "rico", role: :reviewer})

    assert :ok =
             perform_job(BrusselsWtf.Workers.ImportCorpusSource, %{
               corpus_import_batch_id: batch.id,
               meeting_key: meeting["key"],
               source_name: source["name"]
             })

    blocked = Council.get_corpus_import_batch!(batch.id)
    assert blocked.status == :blocked
    assert blocked.failure == "source_drift"
    assert [version_id] = blocked.source_version_ids

    assert BrusselsWtf.Ingestion.get_source_version!(version_id).sha256 ==
             BrusselsWtf.Digest.sha256(changed)

    refute_enqueued worker: BrusselsWtf.Workers.ExtractSource

    assert [review_case] =
             BrusselsWtf.Review.list_review_cases!(%{},
               actor: %Actor{id: "rico", role: :reviewer}
             )

    assert review_case.kind == :acquisition
    assert review_case.summary == "Sealed real-corpus source bytes changed"
  end

  test "oversized or unreadable sealed sources block into actionable acquisition review" do
    meeting = Manifest.meeting!("ixelles-268")
    [source] = meeting["sources"]

    Application.put_env(:brussels_wtf, :corpus_source_loader, fn _path ->
      {:ok, :binary.copy(<<0>>, 2_000_001)}
    end)

    batch = Import.request!([meeting["key"]], %Actor{id: "rico", role: :reviewer})
    assert :ok = Import.import_source(batch.id, meeting["key"], source["name"])

    blocked = Council.get_corpus_import_batch!(batch.id)
    assert blocked.status == :blocked
    assert blocked.failure == "corpus_source_too_large"
    assert blocked.source_version_ids == []
    refute_enqueued worker: BrusselsWtf.Workers.ExtractSource

    assert [review_case] =
             BrusselsWtf.Review.list_review_cases!(%{},
               actor: %Actor{id: "rico", role: :reviewer}
             )

    assert review_case.kind == :acquisition
    assert review_case.affected_record_id == batch.id
    assert review_case.diagnostics["classification"] == "corpus_source_too_large"
    assert review_case.related_evidence["official_url"] == source["url"]
  end

  test "unreadable sealed sources also fail closed into review" do
    meeting = Manifest.meeting!("ixelles-268")
    [source] = meeting["sources"]
    Application.put_env(:brussels_wtf, :corpus_source_loader, fn _path -> {:error, :eacces} end)

    batch = Import.request!([meeting["key"]], %Actor{id: "rico", role: :reviewer})
    assert :ok = Import.import_source(batch.id, meeting["key"], source["name"])

    assert %{status: :blocked, failure: "eacces", source_version_ids: []} =
             Council.get_corpus_import_batch!(batch.id)

    assert [review_case] =
             BrusselsWtf.Review.list_review_cases!(%{},
               actor: %Actor{id: "rico", role: :reviewer}
             )

    assert review_case.diagnostics["classification"] == "eacces"
    refute_enqueued worker: BrusselsWtf.Workers.ExtractSource
  end

  test "Ash refuses to mark an incomplete corpus batch ready" do
    batch = Import.request!(["ixelles-268"], %Actor{id: "rico", role: :reviewer})

    assert_raise Ash.Error.Invalid, ~r/not ready for coverage/, fn ->
      Ash.update!(
        batch,
        %{
          metrics: %{"normalized_items" => 24},
          processing_run_ids: [],
          coverage_run_ids: [],
          review_case_ids: [],
          meeting_page_ids: []
        },
        action: :mark_ready,
        domain: Council
      )
    end
  end
end
