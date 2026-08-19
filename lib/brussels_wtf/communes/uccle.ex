defmodule BrusselsWtf.Communes.Uccle do
  @moduledoc """
  Discovers Uccle council sources from the archive's year and meeting tables.

  Meeting context comes from the table structure. Filenames are retained as
  observations and are never used to construct or correct source URLs.
  """

  @behaviour BrusselsWtf.Communes.Adapter

  @year_section ~r/<h2\b[^>]*>\s*(\d{4})\s*<\/h2>(.*?)(?=<h2\b|\z)/is
  @table ~r/<table\b[^>]*>(.*?)<\/table>/is
  @caption ~r/<caption\b[^>]*>(.*?)<\/caption>/is
  @row ~r/<tr\b[^>]*>(.*?)<\/tr>/is
  @header ~r/<th\b[^>]*>(.*?)<\/th>/is
  @cell ~r/<td\b[^>]*>(.*?)<\/td>/is
  @link ~r/<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)<\/a>/is

  @months %{
    "janvier" => 1,
    "fevrier" => 2,
    "mars" => 3,
    "avril" => 4,
    "mai" => 5,
    "juin" => 6,
    "juillet" => 7,
    "aout" => 8,
    "septembre" => 9,
    "octobre" => 10,
    "novembre" => 11,
    "november" => 11,
    "decembre" => 12
  }

  @impl true
  def discover(html, index_url) when is_binary(html) and is_binary(index_url) do
    case Regex.scan(@year_section, html) do
      [] ->
        {:error, {:invalid_index, :missing_meeting_tables}}

      sections ->
        case parse_sections(sections, index_url) do
          {:ok, 0, _locators} ->
            {:error, {:invalid_index, :missing_meeting_tables}}

          {:ok, _table_count, []} ->
            {:error, {:invalid_index, :no_authoritative_locators}}

          {:ok, _table_count, locators} ->
            {:ok, locators}

          {:error, reason} ->
            {:error, {:invalid_index, reason}}
        end
    end
  end

  defp parse_sections(sections, index_url) do
    Enum.reduce_while(sections, {:ok, 0, []}, fn [_, year, section],
                                                 {:ok, table_count, accumulated} ->
      tables = Regex.scan(@table, section)

      case parse_tables(tables, year, index_url) do
        {:ok, locators} ->
          {:cont, {:ok, table_count + length(tables), accumulated ++ locators}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_tables(tables, year, index_url) do
    Enum.reduce_while(tables, {:ok, []}, fn [_, table], {:ok, accumulated} ->
      case parse_table(table, year, index_url) do
        {:ok, locators} -> {:cont, {:ok, accumulated ++ locators}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_table(table, year, index_url) do
    if Regex.scan(@link, table) == [] do
      {:ok, []}
    else
      with [_, caption] <- Regex.run(@caption, table),
           {:ok, scheduled_on} <- scheduled_on(text(caption), year),
           {:ok, locators} <- parse_rows(Regex.scan(@row, table), scheduled_on, index_url) do
        {:ok, locators}
      else
        nil -> {:error, :missing_meeting_caption}
        :error -> {:error, :invalid_meeting_date}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse_rows(rows, scheduled_on, index_url) do
    Enum.reduce_while(rows, {:ok, []}, fn [_, row], {:ok, accumulated} ->
      links = @link |> Regex.scan(row) |> collapse_duplicate_anchors()

      if links == [] do
        {:cont, {:ok, accumulated}}
      else
        case row_header(row) do
          {:ok, header} ->
            case locators(links, header, scheduled_on, index_url) do
              {:ok, discovered} -> {:cont, {:ok, accumulated ++ discovered}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          :error ->
            {:halt, {:error, :missing_document_role}}
        end
      end
    end)
  end

  defp row_header(row) do
    case Regex.run(@header, row) || Regex.run(@cell, row) do
      [_, header_html] -> {:ok, text(header_html)}
      nil -> :error
    end
  end

  defp collapse_duplicate_anchors(links) do
    {order, by_url} =
      Enum.reduce(links, {[], %{}}, fn [_, href, label_html] = link, {order, by_url} ->
        case Map.fetch(by_url, href) do
          :error ->
            {order ++ [href], Map.put(by_url, href, link)}

          {:ok, [_, _, existing_label]} ->
            if text(existing_label) == "" and text(label_html) != "" do
              {order, Map.put(by_url, href, link)}
            else
              {order, by_url}
            end
        end
      end)

    Enum.map(order, &Map.fetch!(by_url, &1))
  end

  defp locators(links, header, scheduled_on, index_url) do
    Enum.reduce_while(links, {:ok, []}, fn [_, href, label_html], {:ok, accumulated} ->
      label = text(label_html)

      case role(header, label) do
        {:ok, role} ->
          locator = %{
            url: resolve(index_url, href),
            meeting_identifier: Date.to_iso8601(scheduled_on),
            scheduled_on: scheduled_on,
            role: role,
            language: language(role),
            observed_label: label,
            parent_index_url: index_url,
            item_identifier: nil
          }

          {:cont, {:ok, accumulated ++ [locator]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp role(header, label) do
    normalized_header = normalize(header)
    normalized_label = normalize(label)
    complementary? = String.contains?(normalized_label, "complement")

    cond do
      normalized_header == "ordre du jour" and complementary? ->
        {:ok, :complementary_agenda}

      normalized_header == "ordre du jour" ->
        {:ok, :agenda}

      normalized_header == "notes explicatives" and complementary? ->
        {:ok, :complementary_explanatory_note}

      normalized_header == "notes explicatives" ->
        {:ok, :explanatory_note}

      normalized_header == "registre des deliberations" ->
        {:ok, :register}

      normalized_header == "compte-rendu" ->
        {:ok, :minutes}

      String.starts_with?(normalized_header, "questions") ->
        {:ok, :question}

      String.contains?(normalized_header, "interpellations") ->
        {:ok, :interpellation}

      normalized_header == "motions" ->
        {:ok, :motion}

      true ->
        {:error, {:unknown_document_role, header}}
    end
  end

  defp scheduled_on(caption, year) do
    with [_, day, month_name] <- Regex.run(~r/(\d{1,2})(?:\s*er)?\s+([\p{L}]+)/u, caption),
         {:ok, month} <- Map.fetch(@months, normalize(month_name)),
         {:ok, date} <- Date.new(String.to_integer(year), month, String.to_integer(day)) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  defp language(role)
       when role in [
              :agenda,
              :complementary_agenda,
              :explanatory_note,
              :complementary_explanatory_note,
              :register,
              :minutes
            ],
       do: :bilingual

  defp language(_role), do: :fr

  defp resolve(index_url, href), do: index_url |> URI.merge(href) |> URI.to_string()

  defp text(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&#160;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&#039;", "'")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp normalize(value) do
    value
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
