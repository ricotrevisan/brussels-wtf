defmodule BrusselsWtf.Ingestion.ObservabilityTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  import ExUnit.CaptureLog

  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Review.Actor
  alias BrusselsWtf.Workers.FetchLocator

  setup do
    BrusselsWtf.HTTP.Stub.reset()
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Clock.Controlled.set(~U[2026-08-20 12:00:00Z])

    commune =
      Ingestion.create_commune!(%{
        slug: "ixelles",
        name: "Ixelles",
        index_url: "https://example.test/index"
      })

    locator =
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: "https://secret-token@example.test/agenda.pdf?credential=private",
        parent_index_url: commune.index_url,
        meeting_identifier: "268",
        scheduled_on: ~D[2026-08-30],
        role: :agenda,
        language: :fr,
        discovered_at: ~U[2026-08-20 10:00:00Z]
      })

    run =
      Ingestion.request_poll_now!(%{type: :locator, id: locator.id},
        actor: %Actor{id: "rico", role: :reviewer}
      )

    handler_id = "issue-20-observability-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:brussels_wtf, :ingestion, :retrieval, :stop],
          [:brussels_wtf, :ingestion, :archive, :stored],
          [:brussels_wtf, :ingestion, :poll, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    {:ok, locator: locator, run: run}
  end

  test "polling emits correlated metrics and redacted structured logs", %{
    locator: locator,
    run: run
  } do
    BrusselsWtf.HTTP.Stub.put(locator.url, %{
      status: 200,
      headers: %{"content-type" => ["application/pdf"]},
      body: "%PDF observable bytes"
    })

    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log(fn ->
        assert :ok =
                 perform_job(FetchLocator, %{
                   locator_id: locator.id,
                   poll_run_id: run.id,
                   check_key: run.check_key,
                   attempt: 1
                 })
      end)

    assert_receive {:telemetry, [:brussels_wtf, :ingestion, :retrieval, :stop], measurements,
                    metadata}

    assert measurements.count == 1
    assert measurements.changed == 1
    assert metadata.poll_run_id == run.id
    assert metadata.source_locator_id == locator.id
    assert metadata.status == :success

    assert_receive {:telemetry, [:brussels_wtf, :ingestion, :archive, :stored], %{bytes: bytes},
                    %{poll_run_id: poll_run_id}}

    assert bytes == byte_size("%PDF observable bytes")
    assert poll_run_id == run.id
    assert log =~ "ingestion_retrieval_completed"
    refute log =~ "secret-token"
    refute log =~ "credential=private"
    refute log =~ "object_key"
  end
end
