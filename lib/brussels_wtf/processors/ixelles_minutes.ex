defmodule BrusselsWtf.Processors.IxellesMinutes do
  @moduledoc """
  Bounded, fail-closed reader of the official public Ixelles minutes (2026 layout).

  A point's identity is the number printed in its `DD.MM.YYYY/A/NNNN` heading. On a
  meeting with a normalized agenda that number is only accepted when the wording at the
  same agenda number agrees, because real minutes renumber and retitle points. An outcome
  is only accepted when the exact French line and its exact Dutch counterpart are both
  printed; a vote is only recorded when one complete tally directly follows them in both
  languages.

  Nothing is inferred from silence, an agenda, a `DECIDE` paragraph, or a model. A point
  that fails any check is left out of `items`, so its agenda item stays unknown, and is
  listed in the `minutes_receipt`. A document whose identity or structure cannot be
  verified is an ambiguity as a whole, and records nothing.
  """

  @behaviour BrusselsWtf.Processors

  alias BrusselsWtf.Council.VoteTally

  # Layout verified against retained minutes from this date on; see docs/operations/ixelles-minutes.md.
  @first_supported_date ~D[2026-01-01]

  # Exact printed French line => {disposition, exact printed Dutch counterpart}.
  @outcomes %{
    "Le Conseil approuve." => {"approved", "De Raad keurt goed."},
    "Décision prise par scrutin secret. Le Conseil approuve." =>
      {"approved", "Besluit bij geheime stemming. De Raad keurt goed."},
    "Le point est rejeté." => {"rejected", "Het punt wordt verworpen."},
    "Le point est reporté." => {"postponed", "Het punt wordt verdaagd."},
    "Le Conseil prend connaissance." => {"other", "De Raad neemt kennis."},
    "Le Conseil prend acte." => {"other", "De Raad neemt akte."},
    "Le Conseil est informé." => {"other", "De Raad wordt geïnformeerd."},
    "Le Conseil prend acte et répond en séance." =>
      {"other", "De Raad neemt akte en antwoordt in zitting."},
    "Le Conseil prend acte et répondra par écrit." =>
      {"other", "De Raad neemt akte en zal schriftelijk beantwoorden."}
  }

  @dutch_outcomes @outcomes |> Map.values() |> Enum.map(&elem(&1, 1)) |> MapSet.new()

  # Same non-action vocabulary as the agenda normalizer: such a point carries no proposal.
  @non_action_prefixes [
    "interpellation",
    "information au conseil",
    "question orale",
    "communication"
  ]

  @french_months ~w(JANVIER FÉVRIER MARS AVRIL MAI JUIN JUILLET AOÛT SEPTEMBRE OCTOBRE NOVEMBRE DÉCEMBRE)
  @dutch_months ~w(JANUARI FEBRUARI MAART APRIL MEI JUNI JULI AUGUSTUS SEPTEMBER OKTOBER NOVEMBER DECEMBER)

  @heading ~r/^ {4}(\d{2}\.\d{2}\.\d{4})\/([A-Z]+)\/(\d{4})\s{2,}(\S.*)$/u
  @footer ~r/^\s*(Conseil communal - \d{2}\.\d{2}\.\d{4} - Procès verbal public|Gemeenteraad - \d{2}\.\d{2}\.\d{4} - Openbaar proces-verbaal)/u
  @session_close ~r/^\s*Levée de la séance à /u
  @french_tally ~r/\d+\s+votants\s*:/u
  @dutch_tally ~r/\d+\s+stemmers\s*:/u

  @impl true
  def extract(_meta, _bytes), do: {:error, :processor_unimplemented}

  @impl true
  def normalize(input) when is_map(input) do
    with {:ok, context} <- eligible(input),
         :ok <- verify_identity(context),
         {:ok, points} <- read_points(context) do
      build_output(context, points)
    end
  end

  def normalize(_input), do: {:error, :processor_unimplemented}

  defp eligible(input) do
    text = input["text"]
    meeting_identifier = input["meeting_identifier"]

    with "ixelles" <- input["commune_slug"],
         "minutes" <- to_string(input["role"]),
         true <- is_binary(meeting_identifier) and String.trim(meeting_identifier) != "",
         {:ok, date} <- parse_date(input["scheduled_on"]),
         true <- Date.compare(date, @first_supported_date) != :lt,
         true <- is_binary(text) and String.contains?(text, "PROCÈS VERBAL") do
      {:ok,
       %{
         text: text,
         date: date,
         meeting_identifier: meeting_identifier,
         page_count: input["page_count"],
         agenda_items: List.wrap(input["agenda_items"])
       }}
    else
      _other -> {:error, :processor_unimplemented}
    end
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: :error

  defp verify_identity(%{text: text, date: date}) do
    normalized = String.replace(text, ~r/\s+/u, " ")
    dotted = dotted(date)

    french_heading =
      "CONSEIL COMMUNAL DU #{date.day} #{Enum.at(@french_months, date.month - 1)} #{date.year}"

    dutch_heading =
      "GEMEENTERAAD VAN #{date.day} #{Enum.at(@dutch_months, date.month - 1)} #{date.year}"

    missing =
      [
        {"commune_fr", String.contains?(normalized, "COMMUNE D'IXELLES")},
        {"commune_nl", String.contains?(normalized, "GEMEENTE ELSENE")},
        {"meeting_heading",
         String.contains?(normalized, french_heading) and
           String.contains?(normalized, dutch_heading)},
        {"public_minutes_footer",
         String.contains?(normalized, "Conseil communal - #{dotted} - Procès verbal public")}
      ]
      |> Enum.reject(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    if missing == [],
      do: :ok,
      else: ambiguity(%{"missing_markers" => missing})
  end

  defp read_points(context) do
    pages = pages(context.text)
    lines = lines_with_pages(pages)
    dotted = dotted(context.date)

    headings =
      lines
      |> Enum.with_index()
      |> Enum.flat_map(fn {{_page, line}, index} ->
        case Regex.run(@heading, line) do
          [_, date, series, number, first_line] ->
            [%{index: index, date: date, series: series, number: number, first_line: first_line}]

          nil ->
            []
        end
      end)

    close = Enum.find_index(lines, fn {_page, line} -> Regex.match?(@session_close, line) end)
    numbers = Enum.map(headings, &String.to_integer(&1.number))

    cond do
      Enum.any?(headings, &(&1.date != dotted)) ->
        ambiguity(%{"reason" => "heading_date_conflict"})

      Enum.any?(headings, &(&1.series != "A")) ->
        ambiguity(%{"reason" => "unobserved_heading_series"})

      headings == [] ->
        ambiguity(%{"reason" => "no_points"})

      numbers != Enum.to_list(1..length(numbers)) ->
        ambiguity(%{"reason" => "point_numbering_not_contiguous"})

      is_nil(close) or close < List.last(headings).index ->
        ambiguity(%{"reason" => "session_close_missing"})

      true ->
        total = total_pages(pages, context.page_count)
        stops = Enum.map(tl(headings), & &1.index) ++ [close]

        {:ok,
         headings
         |> Enum.zip(stops)
         |> Enum.map(fn {heading, stop} ->
           read_point(heading, Enum.slice(lines, heading.index, stop - heading.index), dotted)
           |> Map.put(:total_pages, total)
         end)}
    end
  end

  # A page's trailing footer and the blank lines around it are not content, so a paragraph
  # split by a page break reads as one paragraph.
  defp lines_with_pages(pages) do
    pages
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {page, number} ->
      page
      |> String.split("\n")
      |> Enum.reverse()
      |> Enum.drop_while(&(String.trim(&1) == "" or Regex.match?(@footer, &1)))
      |> Enum.reverse()
      |> Enum.map(&{number, &1})
    end)
  end

  # Blank pages stay in the list so every later page keeps its printed number. Only the
  # empty remainder after the final form feed is not a page.
  defp pages(text) do
    pages = String.split(text, "\f")

    if pages |> List.last() |> String.trim() == "",
      do: Enum.drop(pages, -1),
      else: pages
  end

  defp total_pages(pages, page_count) do
    if is_integer(page_count) and page_count > 0,
      do: max(page_count, length(pages)),
      else: length(pages)
  end

  defp read_point(heading, block, dotted) do
    body = tl(block)
    identifier = "#{dotted}/A/#{heading.number}"

    %{
      identifier: identifier,
      number: heading.number |> String.to_integer() |> Integer.to_string(),
      wording: wording(heading.first_line, body),
      paragraphs_after_outcome: paragraphs_after_outcome(body),
      reading: read_outcome(body)
    }
  end

  defp wording(first_line, body) do
    rest =
      body
      |> Enum.map(fn {_page, line} -> String.trim(line) end)
      |> Enum.take_while(&(&1 != "" and &1 != "LE CONSEIL," and not outcome_line?(&1)))

    [first_line | rest]
    |> Enum.join(" ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp paragraphs_after_outcome(body) do
    body
    |> Enum.map(fn {_page, line} -> line |> String.replace(~r/\s+/u, " ") |> String.trim() end)
    |> Enum.drop_while(&(not Map.has_key?(@outcomes, &1)))
    |> Enum.drop(1)
    |> Enum.chunk_by(&(&1 == ""))
    |> Enum.reject(&(&1 == [""] or List.first(&1) == ""))
    |> Enum.map(&canonical(Enum.join(&1, " ")))
  end

  defp outcome_line?(line), do: Map.has_key?(@outcomes, line) or line in @dutch_outcomes

  defp read_outcome(body) do
    trimmed =
      body
      |> Enum.map(fn {page, line} ->
        {page, line |> String.replace(~r/\s+/u, " ") |> String.trim()}
      end)
      |> Enum.reject(fn {_page, line} -> line == "" end)

    french = positions(trimmed, &Map.has_key?(@outcomes, &1))
    dutch = positions(trimmed, &(&1 in @dutch_outcomes))

    case {french, dutch} do
      {[], []} ->
        {:unmatched, "no_explicit_outcome"}

      {[{french_index, {page, statement}}], [{dutch_index, {_page, dutch_line}}]} ->
        {disposition, expected_dutch} = Map.fetch!(@outcomes, statement)

        if dutch_line == expected_dutch do
          read_vote(trimmed, french_index, dutch_index)
          |> outcome_result(disposition, statement, page)
        else
          {:unmatched, "french_dutch_outcome_conflict"}
        end

      {[_one], _other} ->
        {:unmatched, "french_dutch_outcome_conflict"}

      {[], _other} ->
        {:unmatched, "french_dutch_outcome_conflict"}

      _multiple ->
        {:unmatched, "multiple_outcomes"}
    end
  end

  defp positions(lines, predicate) do
    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {{_page, line} = entry, index} ->
      if predicate.(line), do: [{index, entry}], else: []
    end)
  end

  defp read_vote(lines, french_index, dutch_index) do
    french_tallies = positions(lines, &Regex.match?(@french_tally, &1))
    dutch_tallies = positions(lines, &Regex.match?(@dutch_tally, &1))

    case {french_tallies, dutch_tallies} do
      {[], []} ->
        :none

      {[{french_tally, {page, french_line}}], [{dutch_tally, {_page, dutch_line}}]}
      when french_tally == french_index + 1 and dutch_tally == dutch_index + 1 ->
        with {:ok, french_counts} <- VoteTally.parse(french_line),
             {:ok, dutch_counts} <- VoteTally.parse(dutch_line) do
          if french_counts == dutch_counts,
            do: {:vote, french_counts, french_line, page},
            else: {:conflict, "french_dutch_tally_conflict"}
        else
          :error -> {:conflict, "unreadable_tally"}
        end

      _other ->
        {:conflict, "unreadable_tally"}
    end
  end

  defp outcome_result({:conflict, reason}, _disposition, _statement, _page),
    do: {:unmatched, reason}

  defp outcome_result(:none, disposition, statement, page),
    do: {:outcome, disposition, statement, page, nil}

  defp outcome_result({:vote, counts, line, vote_page}, disposition, statement, page) do
    if contradicts?(disposition, counts),
      do: {:unmatched, "tally_contradicts_outcome"},
      else: {:outcome, disposition, statement, page, {counts, line, vote_page}}
  end

  defp contradicts?("approved", %{for: for_votes, against: against}), do: for_votes <= against
  defp contradicts?("rejected", %{for: for_votes, against: against}), do: for_votes > against
  defp contradicts?(_disposition, _counts), do: false

  defp build_output(context, points) do
    known = known_rows(context.agenda_items)

    classified = Enum.map(points, &classify(&1, known))

    decided = for {:decided, item, meta} <- classified, do: {item, meta}

    if decided == [] do
      ambiguity(%{"reason" => "minutes_without_decisions"})
    else
      {:ok,
       %{
         "meeting_identifier" => context.meeting_identifier,
         "scheduled_on" => Date.to_iso8601(context.date),
         "agenda" => %{"kind" => "final", "language" => "bilingual"},
         "items" => Enum.map(decided, fn {item, _meta} -> materialize(item, context) end),
         "minutes_receipt" => receipt(classified)
       }}
    end
  end

  defp known_rows(agenda_items) do
    Enum.reduce(agenda_items, %{bare: %{}, dated: %{}}, fn row, acc ->
      identifier = row["authoritative_identifier"]

      cond do
        not is_binary(identifier) -> acc
        String.contains?(identifier, "/") -> put_in(acc, [:dated, identifier], row)
        true -> put_in(acc, [:bare, identifier], row)
      end
    end)
  end

  defp classify(%{reading: reading} = point, known) do
    non_votable? = non_votable?(point.wording)

    case {reading, non_votable?} do
      {{:outcome, disposition, _statement, _page, _vote}, true}
      when disposition in ["approved", "rejected"] ->
        unmatched(point, "non_votable_with_terminal_outcome")

      {_reading, true} ->
        {:non_votable, point}

      {{:unmatched, reason}, false} ->
        unmatched(point, reason)

      {{:outcome, _disposition, _statement, _page, _vote}, false} ->
        identify(point, known)
    end
  end

  defp unmatched(point, reason), do: {:unmatched, point.identifier, reason}

  defp non_votable?(wording) do
    downcased = String.downcase(wording)
    Enum.any?(@non_action_prefixes, &String.starts_with?(downcased, &1))
  end

  # A dated row is what an earlier minutes-only reading created, so it keeps its identity.
  defp identify(point, known) do
    bare = Map.get(known.bare, point.number)

    cond do
      Map.has_key?(known.dated, point.identifier) ->
        {:decided, Map.put(point, :item_identifier, point.identifier), %{minutes_only: true}}

      is_nil(bare) ->
        {:decided, Map.put(point, :item_identifier, point.identifier), %{minutes_only: true}}

      same_wording?(bare["source_wording"], point) ->
        {:decided, Map.put(point, :item_identifier, point.number), %{minutes_only: false}}

      true ->
        unmatched(point, "wording_differs")
    end
  end

  # Compares only letters and digits: the municipal text varies in spacing and punctuation
  # between agenda and minutes ("sans- abrisme", "règlement.et"), never in its words. The
  # agenda reader can also keep the start of a Dutch title in its French wording, which is
  # accepted only when these same minutes open a later paragraph with exactly that text.
  defp same_wording?(agenda_wording, point) do
    agenda = canonical(agenda_wording)
    minutes = canonical(point.wording)

    agenda == minutes or
      (is_binary(agenda) and String.starts_with?(agenda, minutes) and
         dutch_title_start?(String.replace_prefix(agenda, minutes, ""), point))
  end

  defp dutch_title_start?(tail, point),
    do: Enum.any?(point.paragraphs_after_outcome, &String.starts_with?(&1, tail))

  defp canonical(value) when is_binary(value) do
    value |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, "")
  end

  defp canonical(_value), do: nil

  defp materialize(point, context) do
    {:outcome, disposition, statement, page, vote} = point.reading
    applicable_from = Date.to_iso8601(context.date)

    decision =
      %{
        "disposition" => disposition,
        "statement" => statement,
        "evidence" => %{
          "claim" => "decision",
          "excerpt" => statement,
          "location" => location(point, page),
          "applicable_from" => applicable_from
        }
      }
      |> put_vote(vote, point, applicable_from)

    %{
      "item_number" => point.number,
      "authoritative_identifier" => point.item_identifier,
      "source_wording" => point.wording,
      "decisions" => [decision]
    }
  end

  defp put_vote(decision, nil, _point, _applicable_from), do: decision

  defp put_vote(decision, {counts, line, page}, point, applicable_from) do
    Map.put(decision, "vote", %{
      "for" => counts.for,
      "against" => counts.against,
      "abstentions" => counts.abstentions,
      "evidence" => %{
        "claim" => "vote",
        "excerpt" => line,
        "location" => location(point, page),
        "applicable_from" => applicable_from
      }
    })
  end

  defp location(point, page),
    do: "Procès-verbal, point #{point.identifier}, page #{page}/#{point.total_pages}"

  defp receipt(classified) do
    %{
      "points" => length(classified),
      "decided" => Enum.count(classified, &match?({:decided, _, _}, &1)),
      "non_votable" => Enum.count(classified, &match?({:non_votable, _}, &1)),
      "minutes_only" => Enum.count(classified, &match?({:decided, _, %{minutes_only: true}}, &1)),
      "contested" => Enum.count(classified, &contested?/1),
      "unmatched" =>
        for {:unmatched, identifier, reason} <- classified do
          %{"identifier" => identifier, "reason" => reason}
        end
    }
  end

  defp contested?({:decided, %{reading: {:outcome, _, _, _, {counts, _, _}}}, _meta}),
    do: counts.against > 0 or counts.abstentions > 0

  defp contested?(_classified), do: false

  defp ambiguity(details) do
    {:error, {:normalization_ambiguity, Map.put(details, "contract", "ixelles-minutes")}}
  end

  defp dotted(date) do
    :io_lib.format("~2..0B.~2..0B.~4..0B", [date.day, date.month, date.year]) |> to_string()
  end
end
