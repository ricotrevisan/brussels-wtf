defmodule BrusselsWtf.Workers.ProcessCitizenInactivity do
  use Oban.Worker, queue: :maintenance, max_attempts: 5, unique: [period: 86_400]
  require Logger
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    results = BrusselsWtf.Accounts.run_inactivity_retention()
    Logger.info("citizen_inactivity_processed", count: length(results))
    :ok
  end
end
