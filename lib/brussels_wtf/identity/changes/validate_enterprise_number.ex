defmodule BrusselsWtf.Identity.Changes.ValidateEnterpriseNumber do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    number = Ash.Changeset.get_attribute(changeset, :enterprise_number)

    try do
      normalized = BrusselsWtf.Identity.normalize_enterprise_number!(number)
      Ash.Changeset.force_change_attribute(changeset, :enterprise_number, normalized)
    rescue
      ArgumentError ->
        Ash.Changeset.add_error(changeset,
          field: :enterprise_number,
          message: "must be a valid CBE enterprise number"
        )
    end
  end
end
