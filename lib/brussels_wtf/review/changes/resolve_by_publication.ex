defmodule BrusselsWtf.Review.Changes.ResolveByPublication do
  @moduledoc """
  Closes a publication case that a published revision superseded and appends its audit.

  A later gated revision answers any earlier failed attempt at the same page, whatever
  generation that attempt recorded. No reviewer decided this, so the audit names the
  publication system and the exact revision rather than a person.
  """
  use Ash.Resource.Change

  @note "Superseded by a successful publication of this meeting page."

  @impl true
  def change(%{data: %{kind: kind, status: status}} = changeset, _opts, _context)
      when kind != :publication or status != :open do
    Ash.Changeset.add_error(changeset,
      field: :kind,
      message: "only an open publication case can be resolved by a publication"
    )
  end

  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:status, :resolved)
    |> Ash.Changeset.force_change_attribute(:disposition, :superseded_by_publication)
    |> Ash.Changeset.after_action(fn changeset, result ->
      {_audit, notifications} =
        BrusselsWtf.Review.record_publication_resolution!(
          %{
            review_case_id: result.id,
            note: @note,
            details: %{
              "publication_revision_id" =>
                Ash.Changeset.get_argument(changeset, :publication_revision_id),
              "publication_input_hash" =>
                Ash.Changeset.get_argument(changeset, :publication_input_hash),
              "case_generation" => result.processing_generation,
              "trigger" => Atom.to_string(Ash.Changeset.get_argument(changeset, :trigger))
            }
          },
          return_notifications?: true
        )

      {:ok, result, notifications}
    end)
  end
end
