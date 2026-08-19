defmodule BrusselsWtf.Communes.CityOfBrussels do
  @moduledoc """
  Discovers the City of Brussels council sources through its year index,
  meeting document listings, and per-item attachment listings.

  The adapter only resolves hrefs published by the City. It never constructs
  an attachment filename or guesses a neighbouring item URL.
  """

  @behaviour BrusselsWtf.Communes.Adapter

  @meeting_section ~r/<h3\b[^>]*>\s*(\d{2}\/\d{2}\/\d{4})\s*<\/h3>(.*?)(?=<h3\b|$)/is
  @link ~r/<a\b[^>]*\bhref\s*=\s*(["'])(.*?)\1[^>]*>(.*?)<\/a>/is
  @item_marker ~r/point_punt/i
  @item_identifier ~r/point_punt\s*\((\d+)\)/i

  @impl true
  def discover(html, index_url) when is_binary(html) and is_binary(index_url) do
    sections = Regex.scan(@meeting_section, html)

    with false <- sections == [],
         {:ok, locators} <- parse_meeting_sections(sections, index_url),
         false <- locators == [] do
      {:ok, locators}
    else
      true when sections == [] -> {:error, {:invalid_index, :missing_meeting_sections}}
      true -> {:error, {:invalid_index, :no_authoritative_locators}}
      {:error, reason} -> {:error, {:invalid_index, reason}}
    end
  end

  @doc """
  Discovers the next level below a stored City listing locator.

  A `:document_listing` yields per-item listing locators. An `:item_listing`
  yields the exact supporting-document locators published for that item.
  """
  def discover_children(html, %{role: :document_listing} = parent) when is_binary(html) do
    case validate_parent(parent, require_item?: false) do
      :ok -> parse_item_listings(html, parent)
      {:error, reason} -> {:error, {:invalid_listing, reason}}
    end
  end

  def discover_children(html, %{role: :item_listing} = parent) when is_binary(html) do
    case validate_parent(parent, require_item?: true) do
      :ok -> parse_attachments(html, parent)
      {:error, reason} -> {:error, {:invalid_item_listing, reason}}
    end
  end

  def discover_children(_html, %{role: role}), do: {:error, {:unsupported_parent_role, role}}
  def discover_children(_html, _parent), do: {:error, {:unsupported_parent_role, nil}}

  defp parse_meeting_sections(sections, index_url) do
    Enum.reduce_while(sections, {:ok, []}, fn [_, displayed_date, body], {:ok, accumulated} ->
      with {:ok, scheduled_on} <- parse_displayed_date(displayed_date),
           {:ok, locators} <- parse_root_links(body, index_url, scheduled_on) do
        {:cont, {:ok, accumulated ++ locators}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_root_links(body, index_url, scheduled_on) do
    body
    |> links(index_url)
    |> Enum.reduce_while({:ok, []}, fn link, {:ok, accumulated} ->
      case classify_root_link(link, scheduled_on) do
        :ignore ->
          {:cont, {:ok, accumulated}}

        {:ok, role, language} ->
          {:cont,
           {:ok,
            accumulated ++
              [locator(link, index_url, scheduled_on, role, language, nil)]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp classify_root_link(%{url: url, label: label}, scheduled_on) do
    path = URI.parse(url).path || ""

    case Regex.run(~r|/show_documents/(\d{2}-\d{2}-\d{4})(?:s)?/?$|i, path) do
      [_, date] ->
        with {:ok, linked_date} <- parse_path_date(date),
             true <- linked_date == scheduled_on do
          {:ok, :document_listing, :bilingual}
        else
          _ -> {:error, :conflicting_meeting_date}
        end

      nil ->
        classify_root_document(path, label)
    end
  end

  defp classify_root_document(path, label) do
    normalized = String.downcase(label)

    role =
      cond do
        String.starts_with?(normalized, "procès-verbal") -> :minutes
        String.starts_with?(normalized, "proces-verbal") -> :minutes
        String.starts_with?(normalized, "addendum") -> :addendum
        String.starts_with?(normalized, "supplément") -> :supplement
        String.starts_with?(normalized, "supplement") -> :supplement
        String.starts_with?(normalized, "ordre du jour") -> :agenda
        true -> nil
      end

    cond do
      is_nil(role) ->
        :ignore

      not String.ends_with?(String.downcase(path), ".pdf") ->
        {:error, :invalid_document_locator}

      role == :minutes ->
        {:ok, role, :bilingual}

      true ->
        {:ok, role, :fr}
    end
  end

  defp parse_item_listings(html, parent) do
    candidates =
      html
      |> links(parent.url)
      |> Enum.filter(fn link ->
        Regex.match?(@item_marker, link.label) or
          Regex.match?(@item_marker, URI.parse(link.url).path || "")
      end)

    with false <- candidates == [],
         {:ok, locators} <- item_listing_locators(candidates, parent) do
      {:ok, locators}
    else
      true -> {:error, {:invalid_listing, :no_authoritative_item_listings}}
      {:error, reason} -> {:error, {:invalid_listing, reason}}
    end
  end

  defp item_listing_locators(candidates, parent) do
    Enum.reduce_while(candidates, {:ok, []}, fn link, {:ok, accumulated} ->
      identifier_source = link.label <> " " <> (URI.parse(link.url).path || "")

      case Regex.run(@item_identifier, identifier_source) do
        [_, identifier] ->
          if direct_child?(link.url, parent.url) do
            {:cont,
             {:ok,
              accumulated ++
                [
                  locator(
                    link,
                    parent.url,
                    parent.scheduled_on,
                    :item_listing,
                    :bilingual,
                    identifier
                  )
                ]}}
          else
            {:halt, {:error, :item_listing_outside_parent}}
          end

        _ ->
          {:halt, {:error, :invalid_item_identifier}}
      end
    end)
  end

  defp parse_attachments(html, parent) do
    attachments =
      html
      |> links(parent.url)
      |> Enum.filter(&attachment?/1)
      |> Enum.map(fn link ->
        locator(
          link,
          parent.url,
          parent.scheduled_on,
          :supporting_document,
          attachment_language(link),
          parent.item_identifier
        )
      end)

    case attachments do
      [] -> {:error, {:invalid_item_listing, :no_authoritative_attachments}}
      locators -> {:ok, locators}
    end
  end

  defp attachment?(link) do
    path = URI.parse(link.url).path || ""
    downcased = String.downcase(path)

    String.ends_with?(downcased, ".pdf") and
      not String.ends_with?(downcased, "/workflow/procedure.pdf")
  end

  defp attachment_language(link) do
    value = String.downcase(link.label <> " " <> (URI.parse(link.url).path || ""))

    cond do
      String.contains?(value, "raadsbesluit") -> :nl
      String.contains?(value, "gemeenteraad") -> :nl
      Regex.match?(~r/(?:^|[^a-z])nl(?:[^a-z]|$)/u, value) -> :nl
      String.contains?(value, "arrêté") -> :fr
      String.contains?(value, "arrete") -> :fr
      String.contains?(value, "conseil") -> :fr
      Regex.match?(~r/(?:^|[^a-z])fr(?:[^a-z]|$)/u, value) -> :fr
      true -> :bilingual
    end
  end

  defp locator(link, parent_url, scheduled_on, role, language, item_identifier) do
    %{
      url: link.url,
      meeting_identifier: Date.to_iso8601(scheduled_on),
      scheduled_on: scheduled_on,
      role: role,
      language: language,
      observed_label: link.label,
      parent_index_url: parent_url,
      item_identifier: item_identifier,
      dossier_identifier: nil
    }
  end

  defp links(html, parent_url) do
    for [_, _quote, href, label_html] <- Regex.scan(@link, html) do
      %{url: resolve(parent_url, href), label: text(label_html)}
    end
  end

  defp validate_parent(parent, opts) do
    required = [:url, :meeting_identifier, :scheduled_on]

    cond do
      not Enum.all?(required, &Map.has_key?(parent, &1)) ->
        {:error, :missing_parent_context}

      not is_binary(parent.url) or not is_binary(parent.meeting_identifier) or
          not match?(%Date{}, parent.scheduled_on) ->
        {:error, :invalid_parent_context}

      parent.meeting_identifier != Date.to_iso8601(parent.scheduled_on) ->
        {:error, :conflicting_parent_context}

      opts[:require_item?] and
          (not is_binary(Map.get(parent, :item_identifier)) or parent.item_identifier == "") ->
        {:error, :missing_item_identifier}

      true ->
        :ok
    end
  end

  defp direct_child?(url, parent_url) do
    String.starts_with?(url, String.trim_trailing(parent_url, "/") <> "/")
  end

  defp parse_displayed_date(value) do
    case String.split(value, "/") do
      [day, month, year] -> date(year, month, day)
      _ -> {:error, :invalid_meeting_date}
    end
  end

  defp parse_path_date(value) do
    case String.split(value, "-") do
      [day, month, year] -> date(year, month, day)
      _ -> {:error, :invalid_meeting_date}
    end
  end

  defp date(year, month, day) do
    Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day))
    |> case do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_meeting_date}
    end
  rescue
    ArgumentError -> {:error, :invalid_meeting_date}
  end

  defp resolve(parent_url, href), do: parent_url |> URI.merge(href) |> URI.to_string()

  defp text(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&#160;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&#039;", "'")
    |> String.replace("&#39;", "'")
    |> String.replace("&quot;", "\"")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
