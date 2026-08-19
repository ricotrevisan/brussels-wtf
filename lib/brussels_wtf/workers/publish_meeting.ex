defmodule BrusselsWtf.Workers.PublishMeeting do
  @moduledoc false

  use Oban.Worker,
    queue: :publish,
    max_attempts: 3,
    unique: [period: 60, states: :incomplete]

  @impl true
  def perform(%Oban.Job{args: %{"meeting_id" => meeting_id}}) do
    BrusselsWtf.Council.Publication.generate_and_publish(meeting_id)
  end
end
