defmodule BrusselsWtf.Council.VariantMutation do
  @moduledoc "Prevents live public variants from changing outside a staged atomic revision."

  alias BrusselsWtf.Council

  def validate_locale(changeset) do
    changeset
    |> Ash.Changeset.get_attribute(:meeting_page_id)
    |> Council.get_meeting_page!()
    |> require_draft()
  end

  def validate_coverage(changeset) do
    item =
      BrusselsWtf.Council.AgendaItem
      |> Ash.get!(Ash.Changeset.get_attribute(changeset, :agenda_item_id),
        authorize?: false,
        domain: Council
      )
      |> Ash.load!(council_meeting: [:meeting_page])

    case item.council_meeting.meeting_page do
      nil -> :ok
      page -> require_draft(page)
    end
  end

  defp require_draft(%{publication_status: :draft}), do: :ok
  defp require_draft(_page), do: {:error, "published variants require a staged revision"}
end
