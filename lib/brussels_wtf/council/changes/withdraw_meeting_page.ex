defmodule BrusselsWtf.Council.Changes.WithdrawMeetingPage do
  @moduledoc false
  use Ash.Resource.Change

  @locales MapSet.new(["fr", "nl", "en"])

  @impl true
  def change(changeset, _opts, %{actor: %{id: actor_id, role: :reviewer}})
      when is_binary(actor_id) do
    reasons = Ash.Changeset.get_argument(changeset, :reasons)
    occurred_at = Ash.Changeset.get_argument(changeset, :occurred_at)

    if valid_reasons?(reasons) do
      changeset
      |> Ash.Changeset.force_change_attribute(:publication_status, :draft)
      |> Ash.Changeset.force_change_attribute(:withdrawn_at, occurred_at)
      |> Ash.Changeset.force_change_attribute(:withdrawn_by, actor_id)
      |> Ash.Changeset.force_change_attribute(:withdrawal_reasons, reasons)
    else
      Ash.Changeset.add_error(changeset,
        field: :reasons,
        message: "must contain non-blank fr, nl, and en notices"
      )
    end
  end

  def change(changeset, _opts, _context) do
    Ash.Changeset.add_error(changeset, field: :withdrawn_by, message: "requires a reviewer actor")
  end

  defp valid_reasons?(reasons) when is_map(reasons) do
    MapSet.new(Map.keys(reasons)) == @locales and
      Enum.all?(Map.values(reasons), &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp valid_reasons?(_reasons), do: false
end
