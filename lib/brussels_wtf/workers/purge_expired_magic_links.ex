defmodule BrusselsWtf.Workers.PurgeExpiredMagicLinks do
  @moduledoc "Removes expired outstanding citizen magic-link records."
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    :ok = BrusselsWtf.Accounts.cleanup_expired_magic_links()
    :ok
  end
end
