defmodule BrusselsWtf.Workers.PublishMeeting do
  @moduledoc false

  use Oban.Worker,
    queue: :publish,
    max_attempts: 3,
    unique: [period: 60, states: :incomplete]

  @impl true
  def perform(
        %Oban.Job{
          args: %{"meeting_id" => meeting_id},
          attempt: attempt,
          max_attempts: max_attempts
        } = job
      ) do
    generation_kind =
      case job.args["generation_kind"] do
        "backfill" -> :backfill
        _other -> :automatic
      end

    result =
      case generation_kind do
        :automatic ->
          BrusselsWtf.Council.generate_meeting_coverage(meeting_id, attempt, max_attempts)

        :backfill ->
          batch_id = job.args["coverage_batch_id"]

          if BrusselsWtf.Council.coverage_batch_allows?(batch_id, meeting_id) do
            BrusselsWtf.Council.generate_backfill_meeting_coverage(
              meeting_id,
              attempt,
              max_attempts,
              :backfill,
              batch_id
            )
          else
            {:ok, :ok}
          end
      end

    case result do
      {:ok, :ok} -> :ok
      {:error, _reason} -> {:error, :coverage_generation_failed}
    end
  end
end
