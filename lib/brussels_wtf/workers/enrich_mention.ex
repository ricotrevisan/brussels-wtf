defmodule BrusselsWtf.Workers.EnrichMention do
  @moduledoc false
  @max_attempts 3

  use Oban.Worker,
    queue: :enrich,
    max_attempts: @max_attempts,
    unique: [period: :infinity, states: :successful]

  @impl true
  def perform(%Oban.Job{args: %{"request_id" => request_id}, attempt: attempt}) do
    BrusselsWtf.Identity.complete_cbe_enrichment(request_id, attempt, @max_attempts)
  end
end
