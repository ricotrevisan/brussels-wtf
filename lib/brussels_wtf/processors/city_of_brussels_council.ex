defmodule BrusselsWtf.Processors.CityOfBrusselsCouncil do
  @moduledoc """
  Bounded, fail-closed normalizer for City of Brussels council agendas.

  It is commune-specific, not a generic PDF parser. It accepts only an agenda,
  supplement or addendum whose meeting identity the discovery context supplies.
  Supporting documents and every other role stay `:processor_unimplemented`, so
  they never create agenda items. A supplement or addendum adds numbered points to the
  base agenda; it does not restate it.

  The observed layout is a French public-session document:

      VILLE DE BRUXELLES      STAD BRUSSEL
      CONSEIL COMMUNAL DE LA VILLE DE BRUXELLES
      Séance du lundi 12 octobre 2026 à 18 heures
      Ordre du jour | Supplément à l'ordre du jour | Addendum à l'ordre du Jour
      Séance publique
      <section heading>
      [5] <department> - <dossier number> (R)
      <wording>
      ------------
      <title> séance publique du Conseil du lundi 12 octobre 2026    <page>

  The bracketed number is the point's position in this meeting. The dossier number
  is its authoritative identifier, as in the recorded City corpus, so a supplement
  that reissues a dossier updates the same agenda item.

  A meeting in the recorded corpus stays unavailable: its page is sealed to the manifest,
  so a further document of that meeting must not add items to it. Layout findings are
  recorded in `docs/research/2026-11-04-city-of-brussels-agenda-layouts.md`.

  It emits proposals only, never a decision or an outcome. Under ADR 0005, a point
  in a communications, interpellation or question section, and a point the council
  only takes note of, stays an agenda item without a proposal.

  Every excerpt must occur on the one page it cites. Any line or marker outside the
  observed layout returns `{:error, {:normalization_ambiguity, details}}`, which
  opens a private review case instead of guessing. Details hold reasons and page
  numbers, never document wording.
  """

  @behaviour BrusselsWtf.Processors

  @contract "city-of-brussels-council"

  @kinds %{
    "agenda" => {"base", "Ordre du jour"},
    "supplement" => {"supplement", "Supplément à l'ordre du jour"},
    "addendum" => {"addendum", "Addendum à l'ordre du jour"}
  }

  @weekdays ~w(lundi mardi mercredi jeudi vendredi samedi dimanche)
  @months ~w(janvier février mars avril mai juin juillet août septembre octobre novembre décembre)

  @commune_line ~r/^VILLE DE BRUXELLES\s+STAD BRUSSEL$/u
  @council_line "CONSEIL COMMUNAL DE LA VILLE DE BRUXELLES"
  @public_session_line "séance publique"

  @item_line ~r/^\[(\d{1,3})\]\s*(.*)$/u
  @header_end ~r/(?:^|\s)(\d{5,8})\s+\(R\)$/u
  @max_header_lines 3
  @separator_line ~r/^-{10,}$/u

  @votable_heading ~r/^Dossiers de (M\.|Mme) (le|la|l['’])\s?(Bourgmestre|Echevine?|Échevine?)\b/u
  @non_votable_headings ~w(communications interpellation interpellations questions) ++
                          ["interpellation citoyenne", "interpellations citoyennes"]

  @note_verb "Prendre\\s+(?:pour\\s+information|acte\\b|connaissance\\b)"
  @takes_note Regex.compile!("\\b#{@note_verb}", "iu")
  @note_clause Regex.compile!("^#{@note_verb}", "iu")
  @numbered_clause ~r/(?:^|\s)\d\)\s+(?=\p{Lu})/u

  @impl true
  def extract(_meta, _bytes), do: {:error, :processor_unimplemented}

  @impl true
  def normalize(input) when is_map(input) do
    with {:ok, context} <- eligible(input),
         {:ok, pages} <- verify_document(context),
         {:ok, items} <- parse_items(pages, context) do
      {:ok, output(context, items)}
    end
  end

  def normalize(_input), do: {:error, :processor_unimplemented}

  @doc """
  Verifies that `excerpt` occurs in `page_text` after whitespace normalization.
  """
  def verify_excerpt(excerpt, page_text) when is_binary(excerpt) and is_binary(page_text) do
    if String.contains?(normalize_whitespace(page_text), normalize_whitespace(excerpt)),
      do: :ok,
      else: {:error, :excerpt_not_found}
  end

  def verify_excerpt(_excerpt, _page_text), do: {:error, :excerpt_not_found}

  defp eligible(%{"commune_slug" => "city-of-brussels", "role" => role} = input)
       when is_map_key(@kinds, role) do
    with identifier when is_binary(identifier) <- input["meeting_identifier"],
         true <- String.trim(identifier) != "",
         text when is_binary(text) <- input["text"],
         true <- String.trim(text) != "",
         {:ok, date} <- parse_date(input["scheduled_on"]),
         nil <- BrusselsWtf.Corpus.Manifest.meeting_by_identity("city-of-brussels", identifier) do
      {kind, title} = Map.fetch!(@kinds, role)

      {:ok,
       %{
         identifier: identifier,
         date: date,
         text: text,
         kind: kind,
         title: title,
         page_count: input["page_count"]
       }}
    else
      _other -> {:error, :processor_unimplemented}
    end
  end

  defp eligible(_input), do: {:error, :processor_unimplemented}

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: :error

  defp verify_document(context) do
    pages = pages(context.text)
    first_page_lines = pages |> List.first() |> content_lines()

    missing =
      [
        {"meeting_identifier", context.identifier == Date.to_iso8601(context.date)},
        {"commune", commune?(first_page_lines)},
        {"council", Enum.any?(first_page_lines, &(&1 == @council_line))},
        {"meeting_heading", Enum.any?(first_page_lines, &meeting_heading?(&1, context.date))},
        {"document_title", Enum.any?(first_page_lines, &same_text?(&1, context.title))},
        {"public_session", Enum.any?(first_page_lines, &same_text?(&1, @public_session_line))},
        {"page_count", page_count_matches?(context.page_count, pages)}
      ]
      |> Enum.reject(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    case missing do
      [] -> verify_footers(pages, context)
      missing -> ambiguity(%{"missing_markers" => missing})
    end
  end

  defp commune?([first | _rest]), do: Regex.match?(@commune_line, first)
  defp commune?([]), do: false

  defp page_count_matches?(count, pages) when is_integer(count), do: count == length(pages)
  defp page_count_matches?(_count, _pages), do: false

  defp meeting_heading?(line, date),
    do: String.starts_with?(line, "Séance du #{date_label(date)} à ")

  defp verify_footers(pages, context) do
    numbered = Enum.with_index(pages, 1)

    case Enum.reject(numbered, fn {page, number} -> footer?(page, number, context) end) do
      [] ->
        {:ok, numbered}

      unreadable ->
        ambiguity(%{
          "unverified" =>
            Enum.map(unreadable, fn {_page, number} ->
              %{"reason" => "page_footer_unreadable", "page" => number}
            end)
        })
    end
  end

  defp footer?(page, number, context) do
    case page |> content_lines() |> List.last() do
      nil ->
        false

      line ->
        same_text?(
          normalize_whitespace(line),
          "#{context.title} séance publique du Conseil du #{date_label(context.date)} #{number}"
        )
    end
  end

  defp parse_items(numbered, context) do
    total = length(numbered)

    state =
      numbered
      |> body_lines(context)
      |> Enum.reduce(
        %{mode: :between, section: nil, current: nil, blocks: [], errors: []},
        &read_line/2
      )
      |> finish_reading()

    {items, errors} = build_items(Enum.reverse(state.blocks), numbered, total, context)
    errors = Enum.reverse(state.errors) ++ errors

    cond do
      errors != [] -> ambiguity(%{"unverified" => errors})
      items == [] -> ambiguity(%{"missing_markers" => ["agenda_items"]})
      true -> {:ok, items}
    end
  end

  # Footers are verified and removed; the title block is removed from the first page only.
  defp body_lines(numbered, context) do
    numbered
    |> Enum.flat_map(fn {page, number} ->
      page
      |> content_lines()
      |> Enum.drop(-1)
      |> Enum.map(&{number, &1})
    end)
    |> Enum.drop_while(fn {number, line} -> number == 1 and title_block?(line, context) end)
  end

  defp title_block?(line, context) do
    Regex.match?(@commune_line, line) or line == @council_line or
      meeting_heading?(line, context.date) or same_text?(line, context.title) or
      same_text?(line, @public_session_line)
  end

  defp read_line({page, line}, %{mode: :between} = state) do
    case Regex.run(@item_line, line) do
      [_, number, rest] ->
        start_item(state, page, number, rest)

      nil ->
        read_heading(state, page, line)
    end
  end

  defp read_line({page, line}, %{mode: :item} = state) do
    cond do
      Regex.match?(@separator_line, line) ->
        %{state | mode: :between, current: nil, blocks: [finished(state) | state.blocks]}

      match = Regex.run(@item_line, line) ->
        [_, number, rest] = match

        state
        |> add_error("agenda_item_not_terminated", state.current.page)
        |> start_item(page, number, rest)

      true ->
        %{state | current: add_line(state.current, page, line)}
    end
  end

  defp start_item(state, page, number, rest) do
    %{
      state
      | mode: :item,
        current: %{
          number: number,
          page: page,
          section: state.section,
          first_line: rest,
          lines: []
        }
    }
  end

  defp add_line(current, page, line), do: %{current | lines: [{page, line} | current.lines]}

  defp finished(state), do: %{state.current | lines: Enum.reverse(state.current.lines)}

  defp finish_reading(%{mode: :item} = state),
    do: add_error(state, "agenda_item_not_terminated", state.current.page)

  defp finish_reading(state), do: state

  defp read_heading(state, page, line) do
    case section(line) do
      nil -> add_error(state, "agenda_heading_unknown", page)
      section -> %{state | section: section}
    end
  end

  defp section(line) do
    normalized = line |> String.trim_trailing(".") |> String.downcase()

    cond do
      Regex.match?(@votable_heading, line) -> :votable
      normalized == "motions" -> :votable
      normalized in @non_votable_headings -> :non_votable
      true -> nil
    end
  end

  defp add_error(state, reason, page),
    do: %{state | errors: [%{"reason" => reason, "page" => page} | state.errors]}

  defp build_items(blocks, numbered, total, context) do
    {items, errors, _last, _seen} =
      Enum.reduce(blocks, {[], [], 0, MapSet.new()}, fn block, {items, errors, last, seen} ->
        number = String.to_integer(block.number)

        case build_item(block, numbered, total, context) do
          {:ok, item} ->
            dossier = item["authoritative_identifier"]

            sequence_errors =
              [
                {number <= last, "agenda_item_number_not_increasing"},
                {MapSet.member?(seen, dossier), "agenda_item_dossier_repeated"}
              ]
              |> Enum.filter(&elem(&1, 0))
              |> Enum.map(&item_error(elem(&1, 1), block))

            {[item | items], sequence_errors ++ errors, max(number, last),
             MapSet.put(seen, dossier)}

          {:error, reason} ->
            {items, [item_error(reason, block) | errors], max(number, last), seen}
        end
      end)

    {Enum.reverse(items), Enum.reverse(errors)}
  end

  defp item_error(reason, block) do
    %{"reason" => reason, "item_number" => block.number, "page" => block.page}
  end

  defp build_item(block, numbered, total, context) do
    with {:ok, section} <- item_section(block),
         {:ok, dossier, wording_lines} <- read_header(block),
         {:ok, wording} <- wording(wording_lines),
         {:ok, page} <- single_page(block, wording_lines),
         :ok <- verify_cited_page(wording, numbered, page) do
      {:ok, item(block.number, dossier, wording, section, page, total, context)}
    end
  end

  defp item_section(%{section: nil}), do: {:error, "agenda_item_without_section"}
  defp item_section(%{section: section}), do: {:ok, section}

  # A header may wrap, so its dossier number can close on a later line. It must close
  # within the bound, otherwise wording could be consumed as a header.
  defp read_header(block) do
    Enum.reduce_while(0..(@max_header_lines - 1), :none, fn used, _acc ->
      header =
        [block.first_line | block.lines |> Enum.take(used) |> Enum.map(&elem(&1, 1))]
        |> Enum.join(" ")

      case Regex.run(@header_end, header) do
        [_, dossier] -> {:halt, {:ok, dossier, Enum.drop(block.lines, used)}}
        nil -> {:cont, {:error, "agenda_item_header_unreadable"}}
      end
    end)
  end

  defp wording([]), do: {:error, "agenda_item_wording_empty"}

  defp wording(lines) do
    {:ok, lines |> Enum.map_join(" ", &elem(&1, 1)) |> normalize_whitespace() |> String.trim()}
  end

  defp single_page(block, lines) do
    case lines |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
      [page] when page == block.page -> {:ok, page}
      _pages -> {:error, "agenda_item_spans_pages"}
    end
  end

  defp verify_cited_page(wording, numbered, page) do
    {page_text, ^page} = Enum.at(numbered, page - 1)

    case verify_excerpt(wording, page_text) do
      :ok -> :ok
      {:error, :excerpt_not_found} -> {:error, "agenda_item_excerpt_not_found"}
    end
  end

  defp item(number, dossier, wording, section, page, total, context) do
    base = %{
      "item_number" => number,
      "authoritative_identifier" => dossier,
      "source_wording" => wording
    }

    if section == :votable and not information_only?(wording) do
      Map.put(base, "proposals", [
        %{
          "text" => wording,
          "evidence" => %{
            "claim" => "proposal",
            "excerpt" => wording,
            "location" => "#{context.title}, point #{number}, page #{page}/#{total}",
            "applicable_from" => Date.to_iso8601(context.date)
          }
        }
      ])
    else
      base
    end
  end

  # A college decision the council only takes note of is not votable. A point with any
  # numbered action besides taking note still asks the council to act, so it stays a proposal.
  defp information_only?(wording) do
    Regex.match?(@takes_note, wording) and
      @numbered_clause
      |> Regex.split(wording)
      |> Enum.drop(1)
      |> Enum.all?(&Regex.match?(@note_clause, &1))
  end

  defp output(context, items) do
    %{
      "meeting_identifier" => context.identifier,
      "scheduled_on" => Date.to_iso8601(context.date),
      "agenda" => %{"kind" => context.kind, "language" => "fr"},
      "items" => items
    }
  end

  defp ambiguity(details) do
    {:error, {:normalization_ambiguity, Map.put(details, "contract", @contract)}}
  end

  # A blank page inside the document stays, so that its missing footer fails the check.
  defp pages(text) do
    text
    |> String.split("\f")
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.reverse()
    |> case do
      [] -> [""]
      pages -> pages
    end
  end

  defp content_lines(page) do
    page
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp date_label(date) do
    weekday = Enum.at(@weekdays, Date.day_of_week(date) - 1)
    day = if date.day == 1, do: "1er", else: Integer.to_string(date.day)
    "#{weekday} #{day} #{Enum.at(@months, date.month - 1)} #{date.year}"
  end

  defp same_text?(left, right), do: comparable(left) == comparable(right)

  defp comparable(text) do
    text
    |> String.replace("’", "'")
    |> normalize_whitespace()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_whitespace(text), do: String.replace(text, ~r/\s+/u, " ")
end
