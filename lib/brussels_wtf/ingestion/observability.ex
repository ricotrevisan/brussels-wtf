defmodule BrusselsWtf.Ingestion.Observability do
  @moduledoc """
  Low-cardinality ingestion telemetry and safe structured logging.

  Authoritative URLs, object keys, credentials, response bodies, and private
  diagnostics are deliberately excluded from emitted metadata.
  """

  require Logger
  import Ecto.Query

  @safe_metadata [
    :poll_run_id,
    :retrieval_observation_id,
    :source_locator_id,
    :source_version_id,
    :processing_run_id,
    :review_case_id,
    :commune_id,
    :commune_slug,
    :status,
    :classification,
    :processor_role,
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

  def adapter_unavailable(commune_slug) do
    emit(
      [:brussels_wtf, :ingestion, :adapter, :unavailable],
      %{count: 1},
      %{commune_slug: commune_slug, status: :skipped},
      "ingestion_adapter_unavailable"
    )
  end

  def extraction_completed(metadata, duration_ms, rejected_pages) do
    emit(
      [:brussels_wtf, :ingestion, :extraction, :stop],
      %{count: 1, duration_ms: duration_ms, rejected_pages: length(rejected_pages)},
      metadata,
      "ingestion_extraction_completed"
    )
  end

  def ocr_routed(metadata, page_count) do
    emit(
      [:brussels_wtf, :ingestion, :ocr, :routed],
      %{count: 1, pages: page_count},
      metadata,
      "ingestion_ocr_routed"
    )
  end

  def processing_retry(metadata) do
    emit(
      [:brussels_wtf, :ingestion, :processing, :retry],
      %{count: 1},
      metadata,
      "ingestion_processing_retry"
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

  def poll_stopped(run, status, started_monotonic, queue_age) do
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

  def queue_age(%Oban.Job{} = job) do
    started_at = job.attempted_at || BrusselsWtf.Clock.utc_now()
    queued_at = job.scheduled_at || job.inserted_at || started_at
    max(DateTime.diff(started_at, queued_at, :millisecond), 0)
  end

  def measure_ocr_queue do
    states = ["available", "scheduled", "executing", "retryable"]

    {backlog, oldest} =
      BrusselsWtf.Repo.one(
        from job in Oban.Job,
          where: job.queue == "ocr" and job.state in ^states,
          select: {count(job.id), min(job.inserted_at)}
      )

    age_ms =
      if oldest,
        do: max(DateTime.diff(BrusselsWtf.Clock.utc_now(), oldest, :millisecond), 0),
        else: 0

    :telemetry.execute(
      [:brussels_wtf, :ingestion, :ocr, :queue],
      %{backlog: backlog, oldest_age_ms: age_ms},
      %{}
    )

    :ok
  rescue
    _error -> :ok
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
