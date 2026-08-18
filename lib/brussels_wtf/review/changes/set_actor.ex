defmodule BrusselsWtf.Review.Changes.SetActor do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: %{id: actor_id}}) when is_binary(actor_id) do
    Ash.Changeset.force_change_attribute(changeset, :actor_id, actor_id)
  end

  def change(changeset, _opts, _context) do
    Ash.Changeset.add_error(changeset, field: :actor_id, message: "requires a reviewer actor")
  end
end
