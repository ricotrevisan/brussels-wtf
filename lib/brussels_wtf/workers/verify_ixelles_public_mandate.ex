defmodule BrusselsWtf.Workers.VerifyIxellesPublicMandate do
  @moduledoc false

  use Oban.Worker,
    queue: :enrich,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  @impl true
  def perform(%Oban.Job{
        args: %{"fact_id" => fact_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case BrusselsWtf.Identity.IxellesPublicMandateProcessor.process(fact_id) do
      :ok ->
        :ok

      {:error, reason} when attempt >= max_attempts ->
        BrusselsWtf.Identity.IxellesPublicMandateProcessor.open_terminal_review(fact_id, reason)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
