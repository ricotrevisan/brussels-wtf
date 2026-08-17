defmodule BrusselsWtf.Communes.Ixelles do
  @moduledoc """
  Skeletal Ixelles discovery adapter.

  It understands fixture indexes that mark locators with `data-meeting-id`
  and `data-role`. Ticket #16 replaces this with the real municipal parser.
  """

  @behaviour BrusselsWtf.Communes.Adapter

  @locator_re ~r/<a\b[^>]*\bhref="([^"]+)"[^>]*>/i

  @roles %{
    "agenda" => :agenda,
    "supplement" => :supplement,
    "addendum" => :addendum,
    "minutes" => :minutes,
    "register" => :register
  }

  @impl true
  def discover(html, index_url) when is_binary(html) do
    locators =
      @locator_re
      |> Regex.scan(html)
      |> Enum.flat_map(fn [tag, href] ->
        meeting_id = attribute(tag, "data-meeting-id")
        role = tag |> attribute("data-role") |> then(&Map.get(@roles, &1))

        if meeting_id && role do
          [
            %{
              url: href,
              meeting_identifier: meeting_id,
              role: role,
              parent_index_url: index_url
            }
          ]
        else
          []
        end
      end)

    {:ok, locators}
  end

  defp attribute(tag, name) do
    case Regex.run(~r/#{name}="([^"]+)"/i, tag) do
      [_, value] -> value
      _ -> nil
    end
  end
end
