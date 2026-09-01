defmodule BrusselsWtf.Follow.Changes.ClaimCollection do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _, _) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      actor = get_in(changeset.context, [:private, :actor])
      proposed = Ash.Changeset.get_attribute(changeset, :owner_citizen_id)

      cond do
        not is_nil(changeset.data.owner_citizen_id) ->
          error(changeset, "collection is already owned")

        not is_map(actor) or actor[:principal] != :citizen or proposed != actor[:id] ->
          error(changeset, "collection owner must be the authenticated citizen")

        true ->
          changeset
      end
    end)
  end

  defp error(changeset, message),
    do: Ash.Changeset.add_error(changeset, field: :owner_citizen_id, message: message)
end
