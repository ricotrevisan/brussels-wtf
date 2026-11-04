defmodule BrusselsWtf.Processors.UccleCouncil do
  @moduledoc """
  Bounded, fail-closed normalizer for Uccle council agendas.

  It accepts only an `agenda` or `complementary_agenda` whose meeting identity comes
  from the acquisition context, verifies the commune, both dated headings, the agenda
  heading and every page footer, then reads the numbered French points from the observed
  layout: a four-space-indented number, a French paragraph, a blank line or page break,
  and a Dutch paragraph. Layout findings are recorded in
  `docs/research/2026-11-03-uccle-agenda-layouts.md`.

  A complementary agenda restates and renumbers the whole base agenda, so a point number
  is not an identity across documents. Uccle publishes no other identifier, so an item's
  identity is its exact official French wording, scoped to the meeting. The output carries
  `"restates_agenda" => true` so ingestion opens a review case when a restating agenda
  does not carry over an earlier item, instead of leaving it current.

  A meeting in the recorded corpus stays unavailable: its page is sealed to the manifest,
  and an agenda read here would add items to it.

  The normalizer emits proposals only. It never emits decisions and never infers an
  outcome. Anything it cannot verify returns `{:error, {:normalization_ambiguity, details}}`
  so that the ingestion pipeline opens a private review case instead of guessing.
  """

  @behaviour BrusselsWtf.Processors

  @contract "uccle-council"
  @agenda_roles ~w(agenda complementary_agenda)

  @non_votable_prefixes [
    "interpellation",
    "question orale",
    "question écrite",
    "communication",
    "information au conseil"
  ]
  @non_votable_phrases ["prise pour information", "prise de connaissance"]

  # Vocabulary used only to verify which paragraph is French and which is Dutch.
  # It never classifies a fact or an outcome. Words shared by both languages stay out.
  @french_markers MapSet.new(
                    ~w(à au aux avec dans des du dépense entre et la le les l pour par relatif relative sur un une approbation question orale écrite interpellation convention règlement marché procédure documents réfection réaménagement subside subsides octroi modification modifications complémentaire proposition déposée motion commune communal communale conseil registre séance ratification abaissement abrogation appel fin prévention propriétés service rue chaussée avenue annexes rapport évaluation culture)
                  )

  @dutch_markers MapSet.new(
                   ~w(aan bij een en het in met naar op te ten tot uit van voor der goedkeuring vraag mondelinge schriftelijke interpellatie burgerinterpellatie overeenkomst opdracht uitgave herstelling herinrichting heraanleg subsidie toekenning wijziging wijzigingen aanvullend voorstel motie neergelegd gemeente gemeentelijk gemeentelijke gemeenteraad register zitting ratificatie verlaging intrekking oproep eind preventie gemeente-eigendommen dienst straat steenweg laan bijlagen verslag evaluatieverslag cultuur nr betreffende begroting rekening bestuurder vervanging beheersovereenkomst burgerinspraak participatief kwalificatieafdeling departement vertaling volgen zal)
                 )

  @french_months %{
    1 => "JANVIER",
    2 => "FÉVRIER",
    3 => "MARS",
    4 => "AVRIL",
    5 => "MAI",
    6 => "JUIN",
    7 => "JUILLET",
    8 => "AOÛT",
    9 => "SEPTEMBRE",
    10 => "OCTOBRE",
    11 => "NOVEMBRE",
    12 => "DÉCEMBRE"
  }

  @dutch_months %{
    1 => "JANUARI",
    2 => "FEBRUARI",
    3 => "MAART",
    4 => "APRIL",
    5 => "MEI",
    6 => "JUNI",
    7 => "JULI",
    8 => "AUGUSTUS",
    9 => "SEPTEMBER",
    10 => "OKTOBER",
    11 => "NOVEMBER",
    12 => "DECEMBER"
  }

  @item_start ~r/^( {4}(\d{1,3}) {2,})(\S.*)$/u
  @footer ~r/^(?:Conseil communal|Gemeenteraad) - (\d{2}\.\d{2}\.\d{4}) - /u
  @page_marker ~r/^Gemeenteraad - .*\s(\d+)\/(\d+)\s*$/u
  @section_indent 4
  @closed_session ~r/^\s*S[ÉE]ANCE\b.*HUIS[ -]CLOS/mu

  @impl true
  def extract(_meta, _bytes), do: {:error, :processor_unimplemented}

  @impl true
  def normalize(input) when is_map(input) do
    with {:ok, context} <- eligible(input),
         :ok <- verify_identity(context),
         {:ok, items} <- parse_items(context) do
      {:ok, build_output(context, items)}
    end
  end

  def normalize(_input), do: {:error, :processor_unimplemented}

  defp eligible(input) do
    text = input["text"]
    role = input["role"] && to_string(input["role"])

    with true <- input["commune_slug"] == "uccle",
         true <- role in @agenda_roles,
         {:ok, date} <- parse_date(input["scheduled_on"]),
         true <- input["meeting_identifier"] == Date.to_iso8601(date),
         nil <-
           BrusselsWtf.Corpus.Manifest.meeting_by_identity("uccle", input["meeting_identifier"]),
         true <- is_binary(text) and String.trim(text) != "" do
      {:ok,
       %{
         text: text,
         date: date,
         kind: if(role == "agenda", do: "base", else: "complementary"),
         page_count: input["page_count"]
       }}
    else
      _other -> {:error, :processor_unimplemented}
    end
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: :error

  defp verify_identity(%{text: text, date: date, kind: kind}) do
    normalized = squish(text)

    markers = [
      {"commune_fr", "COMMUNE D'UCCLE"},
      {"commune_nl", "GEMEENTE UKKEL"},
      {"meeting_heading_fr",
       "CONSEIL COMMUNAL DU #{date.day} #{Map.fetch!(@french_months, date.month)} #{date.year}"},
      {"meeting_heading_nl",
       "GEMEENTERAAD VAN #{date.day} #{Map.fetch!(@dutch_months, date.month)} #{date.year}"},
      {"agenda_heading", agenda_heading(kind)},
      {"public_session", "SÉANCE PUBLIQUE - OPENBARE ZITTING"}
    ]

    missing =
      for {name, marker} <- markers, not String.contains?(normalized, marker), do: name

    cond do
      missing != [] ->
        {:error,
         {:normalization_ambiguity, %{"contract" => @contract, "missing_markers" => missing}}}

      Regex.match?(@closed_session, text) ->
        {:error,
         {:normalization_ambiguity,
          %{"contract" => @contract, "unexpected_markers" => ["closed_session"]}}}

      true ->
        :ok
    end
  end

  defp agenda_heading("base"), do: "ORDRE DU JOUR AGENDA"
  defp agenda_heading("complementary"), do: "ORDRE DU JOUR COMPLÉMENTAIRE AANVULLENDE AGENDA"

  defp parse_items(context) do
    pages = pages(context.text)
    %{items: parsed, stray: stray} = read_layout(pages)

    page_problems = page_problems(pages, context)
    number_problems = number_problems(parsed)

    {items, item_problems} =
      parsed
      |> Enum.map(&verify_item(&1, context, length(pages)))
      |> Enum.split_with(&match?({:ok, _item}, &1))

    problems =
      page_problems ++
        stray ++
        number_problems ++
        Enum.map(item_problems, &elem(&1, 1)) ++
        duplicate_problems(items) ++
        if(parsed == [], do: [%{"reason" => "agenda_items_missing"}], else: [])

    if problems == [] do
      {:ok, Enum.map(items, &elem(&1, 1))}
    else
      {:error, {:normalization_ambiguity, %{"contract" => @contract, "unverified" => problems}}}
    end
  end

  # Pages keep their index: only the empty remainder after a final form feed is dropped.
  defp pages(text) do
    pages = String.split(text, "\f")
    if List.last(pages) == "", do: Enum.drop(pages, -1), else: pages
  end

  defp page_problems(pages, context) do
    total = length(pages)
    footer_date = Calendar.strftime(context.date, "%d.%m.%Y")

    count_problem =
      if is_integer(context.page_count) and context.page_count != total,
        do: [%{"reason" => "agenda_page_count_mismatch"}],
        else: []

    footer_problems =
      pages
      |> Enum.with_index(1)
      |> Enum.reject(fn {page, number} -> footer_verified?(page, number, total, footer_date) end)
      |> Enum.map(fn {_page, number} ->
        %{"page" => number, "reason" => "agenda_page_footer_mismatch"}
      end)

    count_problem ++ footer_problems
  end

  defp footer_verified?(page, number, total, footer_date) do
    lines = String.split(page, "\n")
    footers = Enum.flat_map(lines, &footer_date/1)
    markers = Enum.flat_map(lines, &page_marker/1)

    length(footers) == 2 and Enum.all?(footers, &(&1 == footer_date)) and
      markers == [{number, total}]
  end

  defp footer_date(line) do
    case Regex.run(@footer, line) do
      [_, date] -> [date]
      nil -> []
    end
  end

  defp page_marker(line) do
    case Regex.run(@page_marker, line) do
      [_, page, total] -> [{String.to_integer(page), String.to_integer(total)}]
      nil -> []
    end
  end

  defp read_layout(pages) do
    state = %{items: [], open: false, pending: nil, stray: []}

    state =
      pages
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {page, number} ->
        page |> String.split("\n") |> Enum.map(&{number, &1})
      end)
      |> Enum.reduce(state, &read_line/2)

    %{
      items: state.items |> Enum.reverse() |> Enum.map(&finish_item/1),
      stray: Enum.reverse(state.stray)
    }
  end

  defp read_line({page, line}, state) do
    cond do
      String.trim(line) == "" ->
        if state.pending == :page, do: state, else: %{state | pending: :blank}

      Regex.match?(@footer, line) ->
        %{state | pending: :page}

      start = Regex.run(@item_start, line) ->
        [_, prefix, number, text] = start

        item = %{
          number: number,
          column: String.length(prefix),
          fragments: [%{page: page, lines: [text]}],
          separators: []
        }

        %{state | items: [item | state.items], open: true, pending: nil}

      # Everything before the first numbered point is the convocation letter.
      state.items == [] ->
        state

      true ->
        read_body_line(page, line, state)
    end
  end

  defp read_body_line(page, line, state) do
    indent = String.length(line) - String.length(String.trim_leading(line))
    text = String.trim(line)
    [item | rest] = state.items

    cond do
      state.open and indent == item.column ->
        %{state | items: [append_line(item, page, text, state.pending) | rest], pending: nil}

      indent == @section_indent and section_heading?(text) ->
        %{state | open: false, pending: nil}

      true ->
        problem = %{"page" => page, "reason" => "agenda_line_outside_item"}
        %{state | open: false, pending: nil, stray: [problem | state.stray]}
    end
  end

  defp append_line(item, _page, text, nil) do
    [fragment | rest] = item.fragments
    %{item | fragments: [%{fragment | lines: [text | fragment.lines]} | rest]}
  end

  defp append_line(item, page, text, separator) do
    %{
      item
      | fragments: [%{page: page, lines: [text]} | item.fragments],
        separators: [separator | item.separators]
    }
  end

  defp finish_item(item) do
    %{
      item
      | fragments:
          item.fragments
          |> Enum.reverse()
          |> Enum.map(fn fragment ->
            %{page: fragment.page, text: fragment.lines |> Enum.reverse() |> Enum.join(" ")}
          end),
        separators: Enum.reverse(item.separators)
    }
  end

  # Section headings are either capitals or a short bilingual "Dienst - Service" pair.
  # A prose line at this indent is a malformed point and must not pass as a heading.
  defp section_heading?(text) do
    String.upcase(text) == text or
      (String.length(text) <= 70 and Regex.match?(~r/^[^.:;]+ - [^.:;]+$/u, text))
  end

  defp number_problems(items) do
    items
    |> Enum.map(&String.to_integer(&1.number))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reject(fn [previous, next] -> next == previous + 1 end)
    |> Enum.map(fn [previous, next] ->
      %{
        "after" => Integer.to_string(previous),
        "item_number" => Integer.to_string(next),
        "reason" => "agenda_item_number_gap"
      }
    end)
  end

  defp duplicate_problems(items) do
    items
    |> Enum.map(fn {:ok, item} -> item end)
    |> Enum.group_by(& &1["authoritative_identifier"])
    |> Enum.filter(fn {_identifier, group} -> length(group) > 1 end)
    |> Enum.flat_map(fn {_identifier, group} ->
      Enum.map(
        group,
        &%{"item_number" => &1["item_number"], "reason" => "agenda_item_wording_duplicated"}
      )
    end)
    |> Enum.sort_by(& &1["item_number"])
  end

  defp verify_item(parsed, context, total) do
    with {:ok, french, dutch} <- split_languages(parsed),
         :ok <- verify_languages(french, dutch) do
      {:ok, item(parsed.number, french, context, total)}
    else
      {:error, reason, details} ->
        {:error, Map.merge(%{"item_number" => parsed.number, "reason" => reason}, details)}
    end
  end

  # The only readable shapes: French, then Dutch, with at most one page break inside
  # either language. A second blank line or page break has no established meaning.
  defp split_languages(%{fragments: [french, dutch], separators: [_separator]}),
    do: {:ok, [french], [dutch]}

  defp split_languages(%{fragments: [first, second, dutch], separators: [:page, :blank]}),
    do: {:ok, [first, second], [dutch]}

  defp split_languages(%{fragments: [french, first, second], separators: [:blank, :page]}),
    do: {:ok, [french], [first, second]}

  defp split_languages(_parsed),
    do: {:error, "agenda_item_paragraphs_unreadable", %{}}

  # Dutch paragraphs legitimately repeat French names ("V.Z.W. Actions pour les familles"),
  # so Dutch needs its own marker and a lower balance than the French, not a negative one.
  defp verify_languages(french, dutch) do
    french_balances = Enum.map(french, &marker_balance(&1.text))
    dutch_text = Enum.map_join(dutch, " ", & &1.text)
    dutch_balance = marker_balance(dutch_text)

    cond do
      Enum.any?(french_balances, &(&1 <= 0)) ->
        {:error, "agenda_item_french_not_dominant",
         %{"marker_balance" => Enum.min(french_balances)}}

      not dutch_marker?(dutch_text) or dutch_balance >= Enum.sum(french_balances) ->
        {:error, "agenda_item_dutch_not_dominant", %{"marker_balance" => dutch_balance}}

      true ->
        :ok
    end
  end

  defp dutch_marker?(text), do: Enum.any?(tokens(text), &MapSet.member?(@dutch_markers, &1))

  defp marker_balance(text) do
    text
    |> tokens()
    |> Enum.reduce(0, fn token, balance ->
      cond do
        MapSet.member?(@french_markers, token) -> balance + 1
        MapSet.member?(@dutch_markers, token) -> balance - 1
        true -> balance
      end
    end)
  end

  defp tokens(text) do
    ~r/[\p{L}-]+/u |> Regex.scan(String.downcase(text)) |> List.flatten()
  end

  defp item(number, french, context, total) do
    wording = french |> Enum.map_join(" ", & &1.text) |> squish()

    base = %{
      "item_number" => number,
      "authoritative_identifier" => identifier(context.date, wording),
      "source_wording" => wording
    }

    if votable?(wording) do
      Map.put(base, "proposals", [
        %{
          "text" => wording,
          "evidence" => %{
            "claim" => "proposal",
            # A wording split by a page break cites the part that occurs on one page.
            "excerpt" => french |> hd() |> Map.fetch!(:text) |> squish(),
            "location" => location(context.kind, number, Enum.map(french, & &1.page), total),
            "applicable_from" => Date.to_iso8601(context.date)
          }
        }
      ])
    else
      base
    end
  end

  defp identifier(date, wording) do
    "uccle-#{Date.to_iso8601(date)}-#{wording |> BrusselsWtf.Digest.sha256() |> String.slice(0, 16)}"
  end

  defp votable?(wording) do
    downcased = String.downcase(wording)

    not (String.starts_with?(downcased, @non_votable_prefixes) or
           String.contains?(downcased, @non_votable_phrases))
  end

  defp location(kind, number, pages, total) do
    label = if kind == "complementary", do: "Ordre du jour complémentaire", else: "Ordre du jour"

    case pages do
      [page] -> "#{label}, point #{number}, page #{page}/#{total}"
      [first, last] -> "#{label}, point #{number}, pages #{first}-#{last}/#{total}"
    end
  end

  defp build_output(context, items) do
    %{
      "meeting_identifier" => Date.to_iso8601(context.date),
      "scheduled_on" => Date.to_iso8601(context.date),
      "agenda" => %{"kind" => context.kind, "language" => "bilingual"},
      "restates_agenda" => true,
      "items" => items
    }
  end

  defp squish(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
end
