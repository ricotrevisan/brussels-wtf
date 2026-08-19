defmodule BrusselsWtfWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("brussels_wtf.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("brussels_wtf.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("brussels_wtf.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("brussels_wtf.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("brussels_wtf.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Ingestion Metrics
      sum("brussels_wtf.ingestion.retrieval.stop.count", tags: [:status]),
      sum("brussels_wtf.ingestion.retrieval.stop.changed"),
      sum("brussels_wtf.ingestion.archive.stored.bytes"),
      sum("brussels_wtf.ingestion.retry.scheduled.count", tags: [:attempt]),
      last_value("brussels_wtf.ingestion.retry.scheduled.delay_seconds", tags: [:attempt]),
      sum("brussels_wtf.ingestion.review_case.created.count", tags: [:classification]),
      sum("brussels_wtf.ingestion.extraction.stop.count", tags: [:processor_role, :status]),
      summary("brussels_wtf.ingestion.extraction.stop.duration_ms", tags: [:processor_role]),
      sum("brussels_wtf.ingestion.extraction.stop.rejected_pages", tags: [:processor_role]),
      sum("brussels_wtf.ingestion.ocr.routed.count"),
      sum("brussels_wtf.ingestion.ocr.routed.pages"),
      sum("brussels_wtf.ingestion.processing.retry.count",
        tags: [:processor_role, :classification]
      ),
      sum("brussels_wtf.ingestion.adapter.unavailable.count", tags: [:commune_slug]),
      summary("brussels_wtf.ingestion.poll.stop.duration", unit: {:native, :millisecond}),
      summary("brussels_wtf.ingestion.poll.stop.queue_age", unit: :millisecond),
      last_value("brussels_wtf.ingestion.health.stale_communes"),
      last_value("brussels_wtf.ingestion.health.repeated_failures"),
      last_value("brussels_wtf.ingestion.ocr.queue.backlog"),
      last_value("brussels_wtf.ingestion.ocr.queue.oldest_age_ms", unit: :millisecond),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      {BrusselsWtf.Ingestion.Observability, :measure_health, []},
      {BrusselsWtf.Ingestion.Observability, :measure_ocr_queue, []}
    ]
  end
end
