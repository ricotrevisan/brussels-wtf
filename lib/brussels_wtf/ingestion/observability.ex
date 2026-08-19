defmodule BrusselsWtf.Ingestion.Observability do
  @moduledoc """
  Low-cardinality ingestion telemetry and safe structured logging.

  Authoritative URLs, object keys, credentials, response bodies, and private
  diagnostics are deliberately excluded from emitted metadata.
  """

  require Logger

  @safe_metadata [
    :poll_run_id,
    :retrieval_observation_id,
    :source_locator_id,
    :source_version_id,
    :review_case_id,
    :commune_id,
    :status,
    :classification,
    :attempt,
    :sha256
  ]

  def retrieval(observation) do
    changed = if observation.status == :success, do: 1, else: 0

    metadata = %{
      poll_run_id: observation.poll_run_id,
      retrieval_observation_id: observation.id,
      source_locator_id: observation.source_locator_id,
      source_version_id: observation.source_version_id,
      status: observation.status,
      sha256: if(changed == 1, do: observation.sha256)
    }

    emit(
      [:brussels_wtf, :ingestion, :retrieval, :stop],
      %{count: 1, changed: changed},
      metadata,
      "ingestion_retrieval_completed"
    )
  end

  def archive_stored(poll_run_id, locator_id, version_id, byte_size) do
    emit(
      [:brussels_wtf, :ingestion, :archive, :stored],
      %{count: 1, bytes: byte_size},
      %{
        poll_run_id: poll_run_id,
        source_locator_id: locator_id,
        source_version_id: version_id
      },
      "ingestion_archive_stored"
    )
  end

  def retry_scheduled(metadata, delay_seconds) do
    emit(
      [:brussels_wtf, :ingestion, :retry, :scheduled],
      %{count: 1, delay_seconds: delay_seconds},
      metadata,
      "ingestion_retry_scheduled"
    )
  end

  def review_case_created(metadata) do
    emit(
      [:brussels_wtf, :ingestion, :review_case, :created],
      %{count: 1},
      metadata,
      "ingestion_review_case_created"
    )
  end

  def poll_stopped(run, status, started_monotonic) do
    now = BrusselsWtf.Clock.utc_now()

    queue_age =
      case run.inserted_at do
        %DateTime{} = inserted_at -> max(DateTime.diff(now, inserted_at, :millisecond), 0)
        _ -> 0
      end

    emit(
      [:brussels_wtf, :ingestion, :poll, :stop],
      %{
        count: 1,
        duration: System.monotonic_time() - started_monotonic,
        queue_age: queue_age
      },
      %{poll_run_id: run.id, commune_id: run.commune_id, status: status},
      "ingestion_poll_completed"
    )
  end

  def measure_health do
    health = BrusselsWtf.Ingestion.poll_health()

    :telemetry.execute(
      [:brussels_wtf, :ingestion, :health],
      %{
        stale_communes: health.stale_commune_count,
        repeated_failures: health.repeated_failure_count
      },
      %{}
    )

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp emit(event, measurements, metadata, message) do
    safe_metadata = Map.take(metadata, @safe_metadata)
    :telemetry.execute(event, measurements, safe_metadata)
    Logger.info(message, Map.to_list(safe_metadata))
    :ok
  end
end
