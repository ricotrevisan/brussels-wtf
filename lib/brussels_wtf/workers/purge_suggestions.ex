defmodule BrusselsWtf.Workers.PurgeSuggestions do
  @moduledoc false

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 300, fields: [:worker], states: :incomplete]

  @impl true
  def perform(%Oban.Job{}) do
    config = Application.fetch_env!(:brussels_wtf, :suggestions)
    limit = config[:purge_batch_size]
    max_batches = config[:purge_max_batches_per_job]

    Enum.reduce_while(1..max_batches, 0, fn _batch, purged ->
      count = BrusselsWtf.Suggestions.purge_due(limit: limit)

      if count == limit,
        do: {:cont, purged + count},
        else: {:halt, purged + count}
    end)

    :ok
  end
end
