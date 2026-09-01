defmodule BrusselsWtf.Workers.SynchronizeRegisteredFeeds do
  @moduledoc "Synchronizes durable citizen feeds from persisted public projections."
  use Oban.Worker, queue: :maintenance, max_attempts: 5, unique: [period: 240]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case BrusselsWtf.Follow.synchronize_registered_feeds() do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
