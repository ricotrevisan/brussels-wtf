defmodule BrusselsWtf.Review.Changes.RejectSuggestionCaseNote do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :review_case_id) do
      nil ->
        changeset

      review_case_id ->
        case Ash.get(BrusselsWtf.Review.Case, review_case_id,
               authorize?: false,
               domain: BrusselsWtf.Review
             ) do
          {:ok, %{kind: :suggestion}} ->
            Ash.Changeset.add_error(changeset,
              field: :review_case_id,
              message: "suggestion notes require the dedicated retention-aware moderation audit"
            )

          _ ->
            changeset
        end
    end
  end
end
