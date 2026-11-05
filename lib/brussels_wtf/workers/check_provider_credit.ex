defmodule BrusselsWtf.Workers.CheckProviderCredit do
  @moduledoc "Hourly, and after a 402, check paid provider credit (see BrusselsWtf.ProviderCredit)."

  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 60, states: :incomplete]

  @impl true
  def perform(%Oban.Job{args: args}) do
    BrusselsWtf.ProviderCredit.check(Map.get(args, "trigger", "scheduled"))
    :ok
  end
end
