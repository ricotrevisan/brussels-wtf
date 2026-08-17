defmodule BrusselsWtf.Council.Changes.SetAgendaItemContinuity do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    authoritative_identifier = Ash.Changeset.get_attribute(changeset, :authoritative_identifier)
    item_number = Ash.Changeset.get_attribute(changeset, :item_number)

    continuity_key =
      case authoritative_identifier do
        value when is_binary(value) and value != "" -> "authoritative:#{value}"
        _ -> "number:#{item_number}"
      end

    Ash.Changeset.force_change_attribute(changeset, :continuity_key, continuity_key)
  end
end
