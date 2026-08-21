defmodule BrusselsWtf.Workers.ReconcileCoverageCost do
  @moduledoc false

  use Oban.Worker,
    queue: :publish,
    max_attempts: 20,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  @reconciliation_attempts 6

  @impl true
  def perform(%Oban.Job{
        attempt: attempt,
        args: %{
          "reservation_id" => reservation_id,
          "coverage_run_id" => coverage_run_id,
          "usage" => usage
        }
      }) do
    attrs = reconciliation_attrs(coverage_run_id, usage)

    case BrusselsWtf.Council.CoverageBudget.reconcile(reservation_id, attrs) do
      {:ok, _reservation} ->
        :ok

      {:error, reason} when attempt >= @reconciliation_attempts ->
        BrusselsWtf.Council.CoverageBudget.fail_reconciliation(
          reservation_id,
          coverage_run_id,
          usage,
          reason
        )
        |> case do
          {:ok, _failed_reservation} -> :ok
          {:error, persistence_reason} -> {:error, persistence_reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconciliation_attrs(coverage_run_id, usage) do
    attrs = %{
      coverage_run_id: coverage_run_id,
      input_usage: Map.take(usage, ["input_tokens", "input_units"]),
      output_usage: Map.take(usage, ["output_tokens", "output_units", "cost_cents"]),
      settled_at: BrusselsWtf.Clock.utc_now()
    }

    case Map.fetch(usage, "cost_cents") do
      {:ok, cost} -> Map.put(attrs, :final_cost_cents, cost)
      :error -> attrs
    end
  end
end
