defmodule BrusselsWtf.Repo.Migrations.AllowItemCorrections do
  use Ecto.Migration

  def up do
    drop constraint(:review_suggestions, :review_suggestions_valid_enums)

    create constraint(:review_suggestions, :review_suggestions_valid_enums,
             check:
               "kind IN ('ownership', 'correction') AND subject_type IN ('legal_entity', 'person', 'agenda_item') AND (subject_type <> 'agenda_item' OR kind = 'correction') AND status IN ('pending', 'rejected', 'approved')"
           )
  end

  def down do
    raise "Item corrections retain private audit history; roll forward instead of removing their subject type"
  end
end
