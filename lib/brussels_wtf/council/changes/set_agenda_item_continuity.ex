defmodule BrusselsWtf.Council.Changes.SetAgendaItemContinuity do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    authoritative_identifier = Ash.Changeset.get_attribute(changeset, :authoritative_identifier)
    item_number = Ash.Changeset.get_attribute(changeset, :item_number)

    continuity_key =
      case {authoritative_identifier, opts[:mode]} do
        {value, _mode} when is_binary(value) and value != "" ->
          "authoritative:#{value}"

        {_value, :authoritative} ->
          source_version_id = Ash.Changeset.get_attribute(changeset, :current_source_version_id)
          "number:#{item_number}:source:#{source_version_id}"

        {_value, :rendered} ->
          "number:#{item_number}"
      end

    changeset
    |> Ash.Changeset.force_change_attribute(:continuity_key, continuity_key)
    |> set_stable_anchor(continuity_key)
  end

  defp set_stable_anchor(changeset, continuity_key) do
    case Ash.Changeset.get_attribute(changeset, :stable_anchor) do
      value when is_binary(value) and value != "" ->
        changeset

      _ ->
        slug =
          continuity_key
          |> String.replace_prefix("authoritative:", "")
          |> String.replace_prefix("number:", "")
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/u, "-")
          |> String.trim("-")
          |> case do
            "" -> "item"
            value -> value
          end

        suffix = continuity_key |> BrusselsWtf.Digest.sha256() |> String.slice(0, 8)

        Ash.Changeset.force_change_attribute(
          changeset,
          :stable_anchor,
          "agenda-item-#{slug}-#{suffix}"
        )
    end
  end
end
