defmodule BrusselsWtf.Review.Changes.CloseSuggestionCase do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(%{data: %{kind: :suggestion, status: :open}} = changeset, _opts, _context) do
    disposition = Ash.Changeset.get_argument(changeset, :disposition)

    changeset
    |> Ash.Changeset.force_change_attribute(:status, :resolved)
    |> Ash.Changeset.force_change_attribute(:disposition, disposition)
  end

  def change(changeset, _opts, _context) do
    Ash.Changeset.add_error(changeset,
      field: :kind,
      message: "only an open suggestion case can be closed by moderation"
    )
  end
end
