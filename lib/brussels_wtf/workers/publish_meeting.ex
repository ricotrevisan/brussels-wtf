defmodule BrusselsWtf.Workers.PublishMeeting do
  @moduledoc false
  use Oban.Worker, queue: :publish, max_attempts: 3

  @impl true
  def perform(%Oban.Job{args: %{"meeting_id" => meeting_id}}) do
    BrusselsWtf.Ingestion.Pipeline.publish(meeting_id)
  end
end
