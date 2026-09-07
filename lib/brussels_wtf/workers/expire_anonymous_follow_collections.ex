defmodule BrusselsWtf.Workers.ExpireAnonymousFollowCollections do
  @moduledoc "Deletes anonymous collections after twelve months without a management use."
  use Oban.Worker, queue: :maintenance, max_attempts: 3
  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, BrusselsWtf.Follow.expire_unused()}
end
