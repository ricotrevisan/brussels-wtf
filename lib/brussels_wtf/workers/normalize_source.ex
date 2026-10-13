defmodule BrusselsWtf.Workers.NormalizeSource do
  @moduledoc false
  @max_attempts 3

  use Oban.Worker,
    queue: :normalize,
    max_attempts: @max_attempts,
    unique: [period: :infinity, states: :successful]

  @impl true
  def perform(%Oban.Job{
        args: %{"processing_run_id" => run_id, "locator_url" => url} = args,
        attempt: attempt
      }) do
    generation_kind = if args["generation_kind"] == "backfill", do: :backfill, else: :automatic

    if args["processor_contract"] &&
         args["processor_contract"] != BrusselsWtf.Processors.normalization_contract() do
      BrusselsWtf.Ingestion.NormalizationReview.open_contract_change(
        run_id,
        args["processor_contract"],
        BrusselsWtf.Processors.normalization_contract()
      )

      {:discard, "normalization contract changed; requeue from the current release"}
    else
      case BrusselsWtf.Ingestion.Pipeline.normalize(
             run_id,
             url,
             attempt,
             @max_attempts,
             generation_kind
           ) do
        {:error, :extraction_only} -> {:discard, "native-only recovery remains held"}
        result -> result
      end
    end
  end
end
