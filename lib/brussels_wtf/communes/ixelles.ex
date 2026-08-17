defmodule BrusselsWtf.Communes.Ixelles do
  @moduledoc """
  Discovers document and direct-recording locators from the authoritative
  Ixelles council index without synthesizing neighbouring URLs.
  """

  @behaviour BrusselsWtf.Communes.Adapter

  @year_table ~r/<h3\b[^>]*>\s*\[(\d{4})\]\s*<\/h3>\s*<table\b[^>]*>(.*?)<\/table>/is
  @row ~r/<tr\b[^>]*>(.*?)<\/tr>/is
  @cell ~r/<td\b[^>]*>(.*?)<\/td>/is
  @link ~r/<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)<\/a>/is

  @impl true
  def discover(html, index_url) when is_binary(html) and is_binary(index_url) do
    tables = Regex.scan(@year_table, html)

    with false <- tables == [],
         {:ok, locators} <- parse_tables(tables, index_url),
         false <- locators == [] do
      {:ok, locators}
    else
      true when tables == [] -> {:error, {:invalid_index, :missing_council_table}}
      true -> {:error, {:invalid_index, :no_authoritative_locators}}
      {:error, reason} -> {:error, {:invalid_index, reason}}
    end
  end

  defp parse_tables(tables, index_url) do
    Enum.reduce_while(tables, {:ok, []}, fn [_, year, table], {:ok, accumulated} ->
      case parse_rows(Regex.scan(@row, table), year, index_url) do
        {:ok, rows} -> {:cont, {:ok, accumulated ++ List.flatten(rows)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_rows(rows, year, index_url) do
    Enum.reduce_while(rows, {:ok, []}, fn [_, row], {:ok, accumulated} ->
      cells = for [_, cell] <- Regex.scan(@cell, row), do: cell

      case parse_row(cells, year, index_url) do
        {:ok, []} -> {:cont, {:ok, accumulated}}
        {:ok, locators} -> {:cont, {:ok, accumulated ++ [locators]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_row(cells, year, index_url) when length(cells) >= 2 do
    with {:ok, scheduled_on} <- scheduled_on(hd(cells), year),
         links <- links(cells, index_url),
         document_links <-
           Enum.filter(links, &match?({role, _} when role != :recording, &1.kind)),
         {:ok, meeting_identifier} <- meeting_identifier(document_links) do
      {:ok,
       Enum.map(document_links ++ Enum.filter(links, &(&1.kind == :recording)), fn link ->
         {role, _identifier} = normalize_kind(link.kind, meeting_identifier)

         %{
           url: link.url,
           meeting_identifier: meeting_identifier,
           scheduled_on: scheduled_on,
           role: role,
           language: language(role),
           observed_label: link.label,
           parent_index_url: index_url,
           item_identifier: nil
         }
       end)}
    else
      :error -> {:ok, []}
      {:error, :no_meeting_identifier} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_row(_cells, _year, _index_url), do: {:ok, []}

  defp links(cells, index_url) do
    for cell <- cells,
        [_, href, label_html] <- Regex.scan(@link, cell),
        url = resolve(index_url, href),
        kind <- [classify(url)],
        kind != :ignore do
      %{url: url, label: text(label_html), kind: kind}
    end
  end

  defp meeting_identifier(document_links) do
    identifiers = document_links |> Enum.map(fn %{kind: {_, id}} -> id end) |> Enum.uniq()

    case identifiers do
      [identifier] -> {:ok, identifier}
      [] -> {:error, :no_meeting_identifier}
      _ -> {:error, :conflicting_meeting_identifiers}
    end
  end

  defp scheduled_on(cell, year) do
    with [_, day, month] <- Regex.run(~r/(\d{2})\/(\d{2})/, text(cell)),
         {:ok, date} <-
           Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day)) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  defp classify(url) do
    uri = URI.parse(url)

    case Regex.run(~r{/conseil/(odj|projets|pv)/(\d+)\.pdf$}i, uri.path || "") do
      [_, "odj", id] ->
        {:agenda, id}

      [_, "projets", id] ->
        {:project, id}

      [_, "pv", id] ->
        {:minutes, id}

      _ ->
        if(uri.host in ["youtube.com", "www.youtube.com", "youtu.be"],
          do: :recording,
          else: :ignore
        )
    end
  end

  defp normalize_kind(:recording, meeting_identifier), do: {:recording, meeting_identifier}
  defp normalize_kind(kind, _meeting_identifier), do: kind

  defp language(:recording), do: :bilingual
  defp language(_document), do: :bilingual

  defp resolve(index_url, href), do: index_url |> URI.merge(href) |> URI.to_string()

  defp text(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&#160;", " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
