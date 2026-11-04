defmodule BrusselsWtf.Processors.ForestCouncil do
  @moduledoc """
  Bounded, fail-closed normalizer for Forest public council agendas.

  This is a commune-specific normalizer, not a generic PDF parser. Meeting identity
  comes from the discovery context and must match the document's own bilingual
  heading, public-session heading, and numbered running footer on every page. The
  layout decides the language split: an item holds a French paragraph, then a Dutch
  paragraph, and either may continue across one page break. The findings behind
  these rules are in `docs/operations/forest-agendas.md`.

  A complementary agenda restates the whole list and keeps the base numbering, so the
  point number scoped to the meeting identifies an item, as in the recorded corpus. With
  `"restates_agenda" => true`, ingestion opens a review case for an earlier point that a
  later agenda drops.

  The normalizer emits proposals only, never decisions, and never infers an outcome.
  Any unverifiable document returns `{:error, {:normalization_ambiguity, details}}`,
  so the pipeline opens a private review case for the whole document. Two limits
  keep sealed history out of reach: meetings before 2026-09-01 stay unavailable,
  and meetings in the recorded corpus open a review case.
  """

  @behaviour BrusselsWtf.Processors

  alias BrusselsWtf.Corpus.Manifest

  @contract "forest-council"
  @first_meeting ~D[2026-09-01]
  @agenda_kinds %{"agenda" => "base", "complementary_agenda" => "complementary"}
  @locations %{"base" => "Ordre du jour", "complementary" => "Ordre du jour complémentaire"}

  # Points that hold no council action (ADR 0005). Forest's "– Information." points are
  # not listed: its minutes record a vote on those acknowledgements, so they are
  # proposals (docs/research/2026-09-11-forest-outcome-audit.md).
  @non_action_prefixes ["interpellation", "question ", "communication", "information au conseil"]

  # Used only to confirm the layout's French/Dutch split. It never classifies a fact.
  @french_markers MapSet.new(
                    ~w(à a accord acquisition adhésion adoption affaires annuels approbation assemblées au aux avec avenant budget centrale choix comptes conditions conseil convention coordination décision des du entre et finances financement informatique information instruction intervention jeunesse la le les logement marché marchés mise modification mode motion nouvelle par partenariat passation personnel pour prévention prise procédure propreté publics quartiers question recette règlement relatif relative remplacement revitalisation rénovation sa service services seniors sports sur subvention subsides travaux une voirie)
                  )

  @dutch_markers MapSet.new(
                   ~w(aan aanhangsel aankoop aankoopcentrale aanleg begroting bestuursorganen betreffende bij burgerinterpellatie dienst dienstjaar een en financiën gemeente gemeenteraad gemeentelijke gewest goedkeuring grondregie het herziening heropleving huisvesting in interpellatie jaarrekeningen jeugd kennisgeving kennisname kennisneming met mobiliteit mondelinge motie nieuwe of onderwijs ontvanger op openbaar opdracht overeenkomst overheidsopdrachten personeel preventie reglement samenwerkingsovereenkomst senioren sociale sport subsidie subsidies tot tussen uit van vervanging voor voorwaarden vraag wegenis wegenissen wijken wijziging zaken)
                 )

  @french_months ~w(JANVIER FÉVRIER MARS AVRIL MAI JUIN JUILLET AOÛT SEPTEMBRE OCTOBRE NOVEMBRE DÉCEMBRE)
  @dutch_months ~w(JANUARI FEBRUARI MAART APRIL MEI JUNI JULI AUGUSTUS SEPTEMBER OKTOBER NOVEMBER DECEMBER)

  @item_start ~r/^ {2,6}(\d{1,3})\s{2,}(\S.*)$/u
  @annex_count ~r/^\s*\d+ annexes? \/ \d+ bijlagen?\s*$/u
  @body_indent ~r/^ {7,}\S/u
  @footer_fr ~r/^\s*Conseil communal - (\d{2}\.\d{2}\.\d{4}) - (Ordre du jour(?: complémentaire)? public)\s*$/u
  @footer_nl ~r/^\s*Gemeenteraad - (\d{2}\.\d{2}\.\d{4}) - \S.*?\s{2,}(\d+)\/(\d+)\s*$/u
  @footer_any ~r/^\s*(Conseil communal|Gemeenteraad) - \d{2}\.\d{2}\.\d{4} - /u
  @location_pages ~r/, pages? (\d+)(?:-(\d+))?\/\d+$/u

  @impl true
  def extract(_meta, _bytes), do: {:error, :processor_unimplemented}

  @impl true
  def normalize(input) when is_map(input) do
    with {:ok, context} <- eligible(input),
         :ok <- not_recorded(context),
         :ok <- verify_identity(context),
         :ok <- verify_kind(context),
         {:ok, pages} <- verify_footers(context),
         {:ok, items} <- parse_items(pages, context) do
      {:ok,
       %{
         "meeting_identifier" => context.meeting_identifier,
         "scheduled_on" => Date.to_iso8601(context.date),
         "agenda" => %{"kind" => context.kind, "language" => "bilingual"},
         "restates_agenda" => true,
         "items" => items
       }}
    end
  end

  def normalize(_input), do: {:error, :processor_unimplemented}

  @doc """
  True when an evidence excerpt occurs, modulo whitespace, on the pages its location
  cites. A multi-page excerpt is checked with only the running footer removed.
  """
  def excerpt_on_cited_pages?(%{"excerpt" => excerpt, "location" => location}, pages)
      when is_binary(excerpt) and is_binary(location) and is_list(pages) do
    case Regex.run(@location_pages, location, capture: :all_but_first) do
      [first] -> contains_excerpt?(cited_pages(pages, first, first), excerpt)
      [first, last] -> contains_excerpt?(cited_pages(pages, first, last), excerpt)
      nil -> false
    end
  end

  def excerpt_on_cited_pages?(_evidence, _pages), do: false

  defp cited_pages(pages, first, last) do
    pages
    |> Enum.slice((String.to_integer(first) - 1)..(String.to_integer(last) - 1))
    |> Enum.map_join("\n", fn page ->
      page |> String.split("\n") |> Enum.reject(&Regex.match?(@footer_any, &1)) |> Enum.join("\n")
    end)
  end

  defp contains_excerpt?(text, excerpt) do
    excerpt != "" and String.contains?(squish(text), squish(excerpt))
  end

  defp eligible(input) do
    with "forest" <- input["commune_slug"],
         {:ok, kind} <- Map.fetch(@agenda_kinds, to_string(input["role"])),
         text when is_binary(text) <- input["text"],
         true <- String.trim(text) != "",
         {:ok, date} <- parse_date(input["scheduled_on"]),
         true <- input["meeting_identifier"] == Date.to_iso8601(date),
         true <- Date.compare(date, @first_meeting) != :lt do
      {:ok,
       %{
         text: text,
         squished: squish(text),
         date: date,
         meeting_identifier: input["meeting_identifier"],
         kind: kind,
         page_count: input["page_count"]
       }}
    else
      _other -> {:error, :processor_unimplemented}
    end
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: :error

  defp not_recorded(context) do
    if Manifest.meeting_by_identity("forest", context.meeting_identifier),
      do: ambiguity(%{"reason" => "recorded_corpus_meeting"}),
      else: :ok
  end

  defp verify_identity(%{squished: text, date: date}) do
    fr_month = Enum.at(@french_months, date.month - 1)
    nl_month = Enum.at(@dutch_months, date.month - 1)
    fr_days = if date.day == 1, do: ["1", "1ER"], else: [to_string(date.day)]

    markers = [
      {"commune_fr", ["ADMINISTRATION COMMUNALE DE FOREST"]},
      {"commune_nl", ["GEMEENTEBESTUUR VORST"]},
      {"meeting_heading_fr",
       Enum.map(fr_days, &"CONSEIL COMMUNAL DU #{&1} #{fr_month} #{date.year}")},
      {"meeting_heading_nl", ["GEMEENTERAAD VAN #{date.day} #{nl_month} #{date.year}"]}
    ]

    missing =
      for {name, options} <- markers,
          not Enum.any?(options, &String.contains?(text, &1)),
          do: name

    cond do
      missing != [] ->
        ambiguity(%{"missing_markers" => missing})

      String.contains?(String.downcase(text), "huis clos") or
          not String.contains?(text, "SÉANCE PUBLIQUE - OPENBARE ZITTING") ->
        ambiguity(%{"reason" => "not_a_public_session_agenda"})

      true ->
        :ok
    end
  end

  defp verify_kind(%{squished: text, kind: kind}) do
    document_kind =
      if String.contains?(text, "ORDRE DU JOUR COMPLÉMENTAIRE"), do: "complementary", else: "base"

    if document_kind == kind, do: :ok, else: ambiguity(%{"reason" => "agenda_kind_mismatch"})
  end

  # Every page must carry the meeting's footer and its own number, so a dropped page,
  # a merged document or a truncated extraction cannot pass as a complete agenda.
  defp verify_footers(%{text: text, page_count: page_count} = context) do
    pages = text |> String.split("\f") |> Enum.reject(&(String.trim(&1) == ""))
    total = length(pages)
    date = Calendar.strftime(context.date, "%d.%m.%Y")

    valid? =
      total == page_count and
        pages
        |> Enum.with_index(1)
        |> Enum.all?(fn {page, number} -> footer_matches?(page, date, number, total, context) end)

    if valid?, do: {:ok, pages}, else: ambiguity(%{"reason" => "page_footer_mismatch"})
  end

  defp footer_matches?(page, date, number, total, %{kind: kind}) do
    label = "#{Map.fetch!(@locations, kind)} public"
    lines = page |> String.split("\n") |> Enum.reject(&(String.trim(&1) == ""))

    with [nl_line, fr_line | _rest] <- Enum.reverse(lines),
         [^date, ^label] <- Regex.run(@footer_fr, fr_line, capture: :all_but_first),
         [^date, page_number, page_total] <-
           Regex.run(@footer_nl, nl_line, capture: :all_but_first) do
      page_number == to_string(number) and page_total == to_string(total)
    else
      _other -> false
    end
  end

  defp parse_items(pages, context) do
    lines = body_lines(pages)
    blocks = item_blocks(lines)
    numbers = Enum.map(blocks, & &1.number)

    if blocks == [] or numbers != Enum.map(1..length(blocks), &to_string/1) do
      ambiguity(%{"reason" => "item_numbers_not_contiguous"})
    else
      results = Enum.map(blocks, &parse_item(&1, pages, context))

      case Enum.filter(results, &match?({:error, _}, &1)) do
        [] ->
          {:ok, Enum.map(results, fn {:ok, item} -> item end)}

        errors ->
          ambiguity(%{"unverified" => Enum.map(errors, fn {:error, reason} -> reason end)})
      end
    end
  end

  defp body_lines(pages) do
    pages
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {page, number} ->
      page
      |> String.split("\n")
      |> Enum.reject(&Regex.match?(@footer_any, &1))
      |> Enum.map(&{number, &1})
    end)
  end

  defp item_blocks(lines) do
    lines
    |> Enum.reduce([], fn {page, line} = entry, blocks ->
      case {Regex.run(@item_start, line), blocks} do
        {[_, number, first], _blocks} ->
          [%{number: number, lines: [{page, String.duplicate(" ", 8) <> first}]} | blocks]

        {nil, []} ->
          []

        {nil, [block | rest]} ->
          [%{block | lines: [entry | block.lines]} | rest]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&Map.update!(&1, :lines, fn lines -> Enum.reverse(lines) end))
  end

  defp parse_item(%{number: number, lines: lines}, pages, context) do
    with {:ok, french, dutch} <- language_paragraphs(lines),
         :ok <- verify_languages(french, dutch),
         wording = paragraph_text(french),
         location = location(context.kind, number, french, length(pages)),
         true <-
           excerpt_on_cited_pages?(%{"excerpt" => wording, "location" => location}, pages) do
      {:ok, item(number, wording, location, context)}
    else
      {:error, reason} -> {:error, %{"item" => number, "reason" => reason}}
      false -> {:error, %{"item" => number, "reason" => "agenda_item_excerpt_not_found"}}
    end
  end

  # Returns the French and Dutch fragments of one item. A section heading or an annex
  # count ends the item's body, so text after either is unreadable, never wording.
  defp language_paragraphs(lines) do
    with {:ok, body} <- item_body(lines) do
      fragments = fragments(body)

      case {fragments, boundaries(fragments)} do
        {[french, dutch], [_boundary]} ->
          {:ok, [french], [dutch]}

        {[french_a, french_b, dutch], [:page, :blank]} ->
          {:ok, [french_a, french_b], [dutch]}

        {[french, dutch_a, dutch_b], [:blank, :page]} ->
          {:ok, [french], [dutch_a, dutch_b]}

        _other ->
          {:error, "agenda_item_paragraphs_unreadable"}
      end
    end
  end

  defp item_body(lines) do
    {body, trailing} = Enum.split_while(lines, fn {_page, line} -> body_line?(line) end)

    after_annex =
      Enum.reject(trailing, fn {_page, line} ->
        String.trim(line) == "" or Regex.match?(@annex_count, line)
      end)

    if Enum.any?(after_annex, fn {_page, line} -> Regex.match?(@body_indent, line) end),
      do: {:error, "agenda_item_paragraphs_unreadable"},
      else: {:ok, body}
  end

  defp body_line?(line) do
    String.trim(line) == "" or
      (Regex.match?(@body_indent, line) and not Regex.match?(@annex_count, line))
  end

  # Splits the body on blank lines and page changes. A page break looks the same whether
  # a paragraph continues or the translation starts; `language_paragraphs/1` resolves it
  # from the blank line that separates the two languages.
  defp fragments(body) do
    body
    |> Enum.chunk_while(
      [],
      fn {page, line} = entry, current ->
        cond do
          String.trim(line) == "" and current == [] ->
            {:cont, []}

          String.trim(line) == "" ->
            {:cont, Enum.reverse(current), []}

          current != [] and elem(hd(current), 0) != page ->
            {:cont, Enum.reverse(current), [entry]}

          true ->
            {:cont, [entry | current]}
        end
      end,
      fn
        [] -> {:cont, []}
        current -> {:cont, Enum.reverse(current), []}
      end
    )
  end

  defp boundaries(fragments) do
    fragments
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [previous, next] ->
      if elem(List.last(previous), 0) == elem(hd(next), 0), do: :blank, else: :page
    end)
  end

  # The French fragments must lean French and the Dutch fragments Dutch, and the pair
  # must differ, so a swapped or unreadable split is a review rather than a claim.
  defp verify_languages(french, dutch) do
    french_scores = Enum.map(french, &score/1)
    dutch_scores = Enum.map(dutch, &score/1)

    if Enum.all?(french_scores, &(&1 >= 0)) and Enum.all?(dutch_scores, &(&1 <= 0)) and
         Enum.sum(french_scores) > Enum.sum(dutch_scores),
       do: :ok,
       else: {:error, "agenda_item_language_unverified"}
  end

  defp score(lines) do
    lines
    |> Enum.map_join(" ", &elem(&1, 1))
    |> String.downcase()
    |> then(&Regex.scan(~r/[\p{L}]+/u, &1))
    |> List.flatten()
    |> Enum.reduce(0, fn token, total ->
      cond do
        MapSet.member?(@french_markers, token) -> total + 1
        MapSet.member?(@dutch_markers, token) -> total - 1
        String.match?(token, ~r/[éèêàçùôî]/u) -> total + 1
        String.match?(token, ~r/(ij|aa|uu|ee|ing$)/u) -> total - 1
        true -> total
      end
    end)
  end

  defp paragraph_text(fragments) do
    fragments |> List.flatten() |> Enum.map_join(" ", &elem(&1, 1)) |> squish() |> String.trim()
  end

  defp location(kind, number, french, total) do
    pages = french |> List.flatten() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    label = Map.fetch!(@locations, kind)

    case pages do
      [page] -> "#{label}, point #{number}, page #{page}/#{total}"
      [first | _rest] -> "#{label}, point #{number}, pages #{first}-#{List.last(pages)}/#{total}"
    end
  end

  defp item(number, wording, location, context) do
    base = %{
      "item_number" => number,
      "authoritative_identifier" => "forest-#{context.meeting_identifier}-#{number}",
      "source_wording" => wording
    }

    if action?(wording) do
      Map.put(base, "proposals", [
        %{
          "text" => wording,
          "evidence" => %{
            "claim" => "proposal",
            "excerpt" => wording,
            "location" => location,
            "applicable_from" => Date.to_iso8601(context.date)
          }
        }
      ])
    else
      base
    end
  end

  defp action?(wording) do
    downcased = String.downcase(wording)
    not Enum.any?(@non_action_prefixes, &String.starts_with?(downcased, &1))
  end

  defp ambiguity(details),
    do: {:error, {:normalization_ambiguity, Map.put(details, "contract", @contract)}}

  defp squish(text), do: String.replace(text, ~r/\s+/u, " ")
end
