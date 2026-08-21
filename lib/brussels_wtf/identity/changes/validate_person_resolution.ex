defmodule BrusselsWtf.Identity.Changes.ValidatePersonResolution do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    basis = Ash.Changeset.get_attribute(changeset, :resolution_basis)
    identifier = Ash.Changeset.get_attribute(changeset, :explicit_identifier)
    facts = Ash.Changeset.get_attribute(changeset, :corroborating_facts) || %{}

    valid? =
      case basis do
        :explicit_identifier -> is_binary(identifier) and String.trim(identifier) != ""
        :corroborated_name -> is_map(facts) and map_size(facts) > 0
        _ -> false
      end

    if valid? do
      changeset
    else
      Ash.Changeset.add_error(changeset,
        field: :resolution_basis,
        message: "requires its stated identity evidence"
      )
    end
  end
end
