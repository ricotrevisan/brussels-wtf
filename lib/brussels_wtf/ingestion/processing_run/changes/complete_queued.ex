defmodule BrusselsWtf.Ingestion.ProcessingRun.Changes.CompleteQueued do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _options, _context) do
    if changeset.data.status == :queued do
      changeset
    else
      Ash.Changeset.add_error(changeset,
        field: :status,
        message: "only a queued processing generation can be completed"
      )
    end
  end
end
