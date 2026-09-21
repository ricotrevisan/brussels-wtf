# Run only through authenticated release RPC. No provider calls or queue drains.
# Default lists safe candidate metadata; full eligibility is checked by preview.
# Code.eval_string(File.read!(Application.app_dir(:brussels_wtf,
#   "priv/ops/private_discovery.exs")), [operation: :preview, run_ids: [...], max_jobs: 8])
# Operations: :candidates, :preview, :enqueue, :status, :pause, :resume,
# :enable_sweep, :sweep_status. Sweep is disabled until explicit enable.
# Preview never prints source text. Enqueue requires explicit IDs and max_jobs.
options = Map.new(binding())
operation = Map.get(options, :operation, :candidates)
config = Application.fetch_env!(:brussels_wtf, :review_auth)
actor = %BrusselsWtf.Review.Actor{id: Keyword.fetch!(config, :actor_id), role: :reviewer}
opts = [actor: actor]

result =
  case operation do
    :candidates ->
      BrusselsWtf.Discovery.candidates(
        opts ++
          [
            limit: Map.get(options, :limit, 10),
            commune: Map.get(options, :commune),
            cursor: Map.get(options, :cursor)
          ]
      )

    action when action in [:preview, :enqueue] ->
      args = [
        Map.fetch!(options, :run_ids),
        opts ++
          [
            max_jobs: Map.fetch!(options, :max_jobs),
            chunk_offset: Map.get(options, :chunk_offset, 0)
          ]
      ]

      case apply(BrusselsWtf.Discovery, action, args) do
        {:ok, report} -> {:ok, Map.drop(report, [:jobs])}
        error -> error
      end

    :enable_sweep ->
      limits = Map.take(options, [:max_runs, :max_jobs, :max_unfinished, :daily_jobs])
      BrusselsWtf.Discovery.enable_sweep(opts ++ Map.to_list(limits))

    :sweep_status ->
      cursors = Map.take(options, [:cursor, :failure_cursor, :event_cursor])
      BrusselsWtf.Discovery.sweep_status(opts ++ Map.to_list(cursors))

    :status ->
      BrusselsWtf.Discovery.status(Map.fetch!(options, :batch_id), opts)

    :pause ->
      BrusselsWtf.Discovery.pause(opts)

    :resume ->
      BrusselsWtf.Discovery.resume(opts)

    _ ->
      {:error, :unsupported_operation}
  end

IO.inspect(result, limit: :infinity, printable_limit: :infinity)
