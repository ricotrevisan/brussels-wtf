defmodule BrusselsWtf.Workers.PublishMeeting do
  @moduledoc false

  use Oban.Worker,
    queue: :publish,
    max_attempts: 3,
    unique: [period: 60, states: :incomplete]

  @impl true
  def perform(%Oban.Job{
        args: %{"meeting_id" => meeting_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case BrusselsWtf.Council.generate_meeting_coverage(meeting_id, attempt, max_attempts) do
      {:ok, :ok} -> :ok
      {:error, _reason} -> {:error, :coverage_generation_failed}
    end
  end
end
