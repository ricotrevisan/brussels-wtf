defmodule BrusselsWtf.Workers.PurgeCitizenFeedUpdates do
  use Oban.Worker, queue: :maintenance, max_attempts: 5, unique: [period: 86_400]
  require Logger
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, count} = BrusselsWtf.Follow.purge_notifications()
    Logger.info("citizen_feed_retention_processed", count: count)
    :ok
  end
end
