defmodule BrusselsWtf.Ingestion.Changes.SetLocatorDiscoveryKey do
  @moduledoc false
  use Ash.Resource.Change

  @fields [
    :parent_index_url,
    :meeting_identifier,
    :scheduled_on,
    :role,
    :language,
    :observed_label,
    :item_identifier,
    :dossier_identifier
  ]

  @impl true
  def change(changeset, _opts, _context) do
    context =
      Map.new(@fields, fn field ->
        {field, normalize(Ash.Changeset.get_attribute(changeset, field))}
      end)

    identity_fields =
      if is_nil(context.dossier_identifier),
        do: Enum.reject(@fields, &(&1 == :dossier_identifier)),
        else: @fields

    canonical =
      identity_fields
      |> Enum.map(fn field -> canonical_part(Map.fetch!(context, field)) end)
      |> Enum.join("|")

    Ash.Changeset.force_change_attribute(
      changeset,
      :discovery_key,
      BrusselsWtf.Digest.sha256(canonical)
    )
  end

  defp canonical_part(nil), do: "~"
  defp canonical_part(value), do: "#{byte_size(value)}:#{value}"

  defp normalize(%Date{} = date), do: Date.to_iso8601(date)
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value), do: value
end
