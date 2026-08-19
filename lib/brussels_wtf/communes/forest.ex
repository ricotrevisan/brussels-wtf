defmodule BrusselsWtf.Communes.Forest do
  @moduledoc """
  Discovers Forest council sources from the authoritative dated publication cards.

  Meeting identity comes from the card's published datetime. File names are kept
  as exact locators but are never used to infer the meeting date.
  """

  @behaviour BrusselsWtf.Communes.Adapter

  @div_token ~r/<div\b[^>]*>|<\/div\s*>/is
  @class_attribute ~r/\bclass\s*=\s*["']([^"']*)["']/is
  @datetime ~r/<time\b[^>]*\bdatetime\s*=\s*["']([^"']+)["'][^>]*>/is
  @date_container ~r/<div\b[^>]*\bclass\s*=\s*["'][^"']*\bdate\b[^"']*["']/is
  @link ~r/<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)<\/a>/is

  @impl true
  def discover(html, index_url) when is_binary(html) and is_binary(index_url) do
    case dated_cards(html) do
      {:ok, []} ->
        {:error, {:invalid_index, :missing_council_cards}}

      {:ok, cards} ->
        case parse_cards(cards, index_url) do
          {:ok, []} -> {:error, {:invalid_index, :no_authoritative_locators}}
          {:ok, locators} -> {:ok, locators}
          {:error, reason} -> {:error, {:invalid_index, reason}}
        end

      {:error, reason} ->
        {:error, {:invalid_index, reason}}
    end
  end

  defp dated_cards(html) do
    with {:ok, cards} <- card_sections(html) do
      Enum.reduce_while(cards, {:ok, []}, fn card, {:ok, dated} ->
        case card_datetime(card) do
          :not_dated -> {:cont, {:ok, dated}}
          {:ok, _datetime} -> {:cont, {:ok, dated ++ [card]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp card_sections(html) do
    tokens = Regex.scan(@div_token, html, return: :index)

    {depth, current, cards} =
      Enum.reduce(tokens, {0, nil, []}, fn [{index, length}], {depth, current, cards} ->
        token = binary_part(html, index, length)

        if opening_div?(token) do
          next_depth = depth + 1

          next_current =
            if is_nil(current) and card_div?(token), do: {index, next_depth}, else: current

          {next_depth, next_current, cards}
        else
          {next_current, next_cards} =
            case current do
              {start, ^depth} ->
                section = binary_part(html, start, index + length - start)
                {nil, cards ++ [section]}

              _other ->
                {current, cards}
            end

          {max(depth - 1, 0), next_current, next_cards}
        end
      end)

    cond do
      not is_nil(current) -> {:error, :malformed_council_card}
      depth != 0 -> {:error, :malformed_index_markup}
      true -> {:ok, cards}
    end
  end

  defp opening_div?(token), do: token |> String.downcase() |> String.starts_with?("<div")

  defp card_div?(token) do
    case Regex.run(@class_attribute, token) do
      [_, classes] -> "card" in String.split(classes)
      _other -> false
    end
  end

  defp card_datetime(card) do
    case Regex.scan(@datetime, card) do
      [[_, value]] ->
        parse_datetime(value)

      [] ->
        if Regex.match?(@date_container, card),
          do: {:error, :invalid_meeting_date},
          else: :not_dated

      _many ->
        {:error, :ambiguous_meeting_date}
    end
  end

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _other -> {:error, :invalid_meeting_date}
    end
  end

  defp parse_cards(cards, index_url) do
    Enum.reduce_while(cards, {:ok, []}, fn card, {:ok, accumulated} ->
      case parse_card(card, index_url) do
        {:ok, locators} -> {:cont, {:ok, accumulated ++ locators}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_card(card, index_url) do
    with {:ok, datetime} <- card_datetime(card),
         {:ok, links} <- authoritative_links(card, index_url),
         false <- links == [] do
      scheduled_on = DateTime.to_date(datetime)
      meeting_identifier = Date.to_iso8601(scheduled_on)

      {:ok,
       Enum.map(links, fn link ->
         %{
           url: link.url,
           meeting_identifier: meeting_identifier,
           scheduled_on: scheduled_on,
           role: link.role,
           language: language(link.role),
           observed_label: link.label,
           parent_index_url: index_url,
           item_identifier: nil
         }
       end)}
    else
      false -> {:error, :no_authoritative_locators}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authoritative_links(card, index_url) do
    Enum.reduce_while(Regex.scan(@link, card), {:ok, []}, fn [_, href, label_html],
                                                             {:ok, links} ->
      label = text(label_html)

      case classify(label, URI.decode(href)) do
        {:ok, role} ->
          link = %{url: resolve(index_url, href), label: label, role: role}
          {:cont, {:ok, links ++ [link]}}

        :error ->
          {:halt, {:error, {:unknown_source_role, label}}}
      end
    end)
  end

  defp classify(label, href) do
    normalized = String.downcase(label)
    source = String.downcase(label <> " " <> href)

    cond do
      String.contains?(source, "agenda compl") ->
        {:ok, :complementary_agenda}

      String.contains?(source, "notes") and String.contains?(source, "compl") ->
        {:ok, :complementary_explanatory_note}

      String.starts_with?(normalized, "ordre du jour complémentaire") ->
        {:ok, :complementary_agenda}

      String.starts_with?(normalized, "ordre du jour complementaire") ->
        {:ok, :complementary_agenda}

      String.starts_with?(normalized, "ordre du jour") ->
        {:ok, :agenda}

      String.starts_with?(normalized, "notes explicatives") ->
        {:ok, :explanatory_notes}

      String.starts_with?(normalized, "procès verbal") ->
        {:ok, :minutes}

      String.starts_with?(normalized, "proces verbal") ->
        {:ok, :minutes}

      String.starts_with?(normalized, "motion") ->
        {:ok, :motion}

      String.contains?(normalized, "interpellation") ->
        {:ok, :interpellation}

      true ->
        :error
    end
  end

  defp language(role) when role in [:motion, :interpellation], do: :fr
  defp language(_role), do: :bilingual

  defp resolve(index_url, href) do
    href = String.replace(href, "&amp;", "&")
    index_url |> URI.merge(href) |> URI.to_string()
  end

  defp text(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&#160;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
