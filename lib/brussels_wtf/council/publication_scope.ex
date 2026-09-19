defmodule BrusselsWtf.Council.PublicationScope do
  @moduledoc "Builds and restores explicit or publishable agenda-item publication scopes."

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.PublicationInput

  @scope_key "publication_scope"

  def for_batch!(meeting, nil) do
    input = PublicationInput.build(meeting)
    {PublicationInput.scope_meeting(meeting, input), input}
  end

  def for_batch!(meeting, coverage_batch_id) do
    batch = Council.get_coverage_batch!(coverage_batch_id)

    case batch.item_scopes do
      scopes when scopes == %{} ->
        input = PublicationInput.build(meeting)
        {PublicationInput.scope_meeting(meeting, input), input}

      scopes ->
        keys = Map.fetch!(scopes, meeting.id)
        scoped = select!(meeting, keys)
        {scoped, explicit_input(scoped, keys)}
    end
  end

  def selection(
        meeting,
        %{@scope_key => %{"mode" => "explicit_items", "item_keys" => keys}} = input
      )
      when is_list(keys) do
    with true <- MapSet.new(keys) == input_item_keys(input),
         {:ok, scoped} <- select(meeting, keys) do
      {:ok, scoped}
    else
      _other -> {:error, :invalid_publication_scope}
    end
  end

  def selection(meeting, input) when is_map(input) and not is_map_key(input, @scope_key),
    do: {:ok, PublicationInput.scope_meeting(meeting, input)}

  def selection(_meeting, _input), do: {:error, :invalid_publication_scope}

  def restore(meeting, input) do
    with {:ok, selected} <- selection(meeting, input) do
      current_input =
        case input do
          %{@scope_key => %{"item_keys" => keys}} -> explicit_input(selected, keys)
          _unscoped -> PublicationInput.build(meeting)
        end

      {:ok, {selected, current_input}}
    end
  end

  def restore!(meeting, input) do
    case restore(meeting, input) do
      {:ok, scoped} -> scoped
      {:error, reason} -> raise ArgumentError, to_string(reason)
    end
  end

  defp explicit_input(meeting, keys) do
    meeting
    |> PublicationInput.build()
    |> Map.put(@scope_key, %{"mode" => "explicit_items", "item_keys" => Enum.sort(keys)})
  end

  defp input_item_keys(%{"items" => items}) when is_list(items),
    do: MapSet.new(items, & &1["key"])

  defp input_item_keys(_input), do: MapSet.new()

  defp select(meeting, keys) when is_list(keys) do
    requested = MapSet.new(keys)

    selected =
      Enum.filter(meeting.agenda_items, fn item ->
        MapSet.member?(requested, item.authoritative_identifier || item.continuity_key)
      end)

    actual =
      MapSet.new(selected, fn item -> item.authoritative_identifier || item.continuity_key end)

    if keys != [] and length(keys) == MapSet.size(requested) and actual == requested,
      do: {:ok, %{meeting | agenda_items: selected}},
      else: {:error, :invalid_publication_scope}
  end

  defp select(_meeting, _keys), do: {:error, :invalid_publication_scope}

  defp select!(meeting, keys) do
    case select(meeting, keys) do
      {:ok, scoped} -> scoped
      {:error, reason} -> raise ArgumentError, to_string(reason)
    end
  end
end
