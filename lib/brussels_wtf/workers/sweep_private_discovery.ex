defmodule BrusselsWtf.Workers.SweepPrivateDiscovery do
  @moduledoc "Bounded archive admission only; never runs inference or drains another queue."
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  @impl true
  def perform(%Oban.Job{}) do
    case BrusselsWtf.Discovery.sweep_tick() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
