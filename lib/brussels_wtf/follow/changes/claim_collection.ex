defmodule BrusselsWtf.Follow.Changes.ClaimCollection do
  @moduledoc false
  use Ash.Resource.Change
  @impl true
  def change(changeset, _, _) do
    if is_nil(changeset.data.owner_citizen_id),
      do: changeset,
      else:
        Ash.Changeset.add_error(changeset,
          field: :owner_citizen_id,
          message: "collection is already owned"
        )
  end
end
