defmodule BrusselsWtf.Review.Changes.RejectSuggestionCaseAction do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(%{data: %{kind: :suggestion}} = changeset, _opts, _context) do
    Ash.Changeset.add_error(changeset,
      field: :kind,
      message: "suggestion cases require the dedicated moderation workflow"
    )
  end

  def change(changeset, _opts, _context), do: changeset
end
