defmodule BrusselsWtf.Processors.IxellesCouncil do
  @moduledoc """
  Bounded, fail-closed normalizer for Ixelles council agenda documents.

  This is a commune-specific normalizer, not a generic PDF parser. It accepts
  only an Ixelles agenda-shaped document whose meeting identity is supplied by
  the acquisition context: `commune_slug`, `meeting_identifier`, `scheduled_on`,
  and an agenda `role`. It verifies the commune and dated council headings in
  the extracted text, then reads the numbered French agenda points and their
  Dutch translations from the observed layout.

  The normalizer emits proposals only. It never emits decisions and never
  infers an outcome from an agenda, silence, a livestream, a disappearance, or
  model output. Any missing identity marker or unverifiable item evidence
  returns `{:error, {:normalization_ambiguity, details}}` so that the ingestion
  pipeline opens a private review case instead of guessing.
  """

  @behaviour BrusselsWtf.Processors

  @agenda_roles ~w(agenda complementary_agenda supplement addendum)

  @non_action_prefixes [
    "interpellation",
    "information au conseil",
    "question orale",
    "communication"
  ]

  # Commune-specific vocabulary used only to separate the French agenda point
  # from its Dutch translation. It never classifies a fact or an outcome.
  @french_markers MapSet.new(
                    ~w(accord-cadre acte afin annexes annee annees approbation article assurance au aux avec avenue avocat belge bien bordereau budget budgetaire batiment beneficiaire cession cette chaleur chauffage citoyenne communal commune conception conditions conseil construction convention coordination cuisine dans des destines dossier du durable duree decisions demolition depense designation en entre entretien est et europeenne exercice exercices fabrication faisant fixation fondations formulaire fournitures immeuble immobilier information inscription interpellation intersection integres interieur isolation la laureat le les loi lors maintenance maison marche mobilier mobilite montant montants metres non notariee nouvelle numeraire objet octroi offre ouverte par participation place plans pompe pose pour prise prix procedure projet public publicite publics publique quartier qui reconstruction relatif relative renforcement rue reamenagement reasphaltage renovation reparation reversible sa service services ses site situe son sont sous stabilisation subvention subventions suivi sur terrain theatre toitures travaux un une vente ventilation vers voiries echevins ecole equipements etudes evaluee)
                  )

  @dutch_markers MapSet.new(
                   ~w(aan aanduiding aankoopcentrale aanleg advokaat afbraak akteneming alsook bedrag begroting begrotingsartikel begunstigde bestemd bestrating betreffende bij bijkomende boeking bouw code coordinatie dak der diensten duurzaam een funderingen gebouw gemeente gemeentelijk geraamd geval goedkeuring gunning herinrichting hernieuwing heropbouw herstelling het in installatie isolatie kennisgeving keuken levering leveringen lot luchtverversing mededelingen met meubilair nr onderhoud ontwerp op opdracht opening opneming opvolging overeenkomst overeenkomsten overheidsopdracht perceel plaatsing plein projectsubsidie raamovereenkomst renovatie stedenbouw straat studies subsidie ten theater toekenning tot uit uitgave uitvoering van vaststelling verlenging versteviging vervaardiging verwarming verzekering voor voorwerp vragen vzw warmtepomp wegenis werken werkingssubsidie wijkcontract wijziging woning worden zijn)
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

  @item_start ~r/^ {4}(\d{1,3})\s{2,}(\S.*)$/u
  @item_prefix ~r/^\s*\d{1,3}\s{2,}/u
  @footer ~r/^\s*(Conseil communal|Gemeenteraad)\s*-/u

  @impl true
  def extract(_meta, _bytes), do: {:error, :processor_unimplemented}

  @impl true
  def normalize(input) when is_map(input) do
    with {:ok, context} <- eligible(input) do
      normalize_eligible(context)
    end
  end

  def normalize(_input), do: {:error, :processor_unimplemented}

  @doc """
  Verifies that `excerpt` really occurs in `page_text` after whitespace
  normalization. Evidence excerpts are never emitted without this check.
  """
  def verify_excerpt(excerpt, page_text) when is_binary(excerpt) and is_binary(page_text) do
    if String.contains?(normalize_whitespace(page_text), normalize_whitespace(excerpt)),
      do: :ok,
      else: {:error, :excerpt_not_found}
  end

  def verify_excerpt(_excerpt, _page_text), do: {:error, :excerpt_not_found}

  defp eligible(input) do
    text = input["text"]
    meeting_identifier = input["meeting_identifier"]
    scheduled_on = input["scheduled_on"]

    with true <- Map.get(input, "commune_slug") == "ixelles",
         true <- is_binary(meeting_identifier) and String.trim(meeting_identifier) != "",
         {:ok, date} <- parse_date(scheduled_on),
         true <- is_binary(text) and String.trim(text) != "",
         :ok <- eligible_role(Map.get(input, "role")),
         true <- agenda_document?(text) do
      {:ok,
       %{
         text: text,
         meeting_identifier: meeting_identifier,
         date: date,
         kind: agenda_kind(text, Map.get(input, "role")),
         language: agenda_language(Map.get(input, "language")),
         page_count: Map.get(input, "page_count")
       }}
    else
      _other -> {:error, :processor_unimplemented}
    end
  end

  defp eligible_role(nil), do: :ok

  defp eligible_role(role) do
    if to_string(role) in @agenda_roles, do: :ok, else: :error
  end

  defp agenda_document?(text) do
    normalized = normalize_whitespace(text)

    String.contains?(normalized, "ORDRE DU JOUR") or
      String.contains?(normalized, "AANVULLENDE AGENDA") or
      String.contains?(normalized, "AGENDA VAN")
  end

  defp agenda_kind(text, role) do
    normalized = normalize_whitespace(text)
    role = if is_nil(role), do: nil, else: to_string(role)

    cond do
      role == "supplement" -> "supplement"
      role == "addendum" -> "addendum"
      role == "complementary_agenda" -> "complementary"
      String.contains?(normalized, "ORDRE DU JOUR COMPLÉMENTAIRE") -> "complementary"
      String.contains?(normalized, "AANVULLENDE AGENDA") -> "complementary"
      String.contains?(normalized, "ADDENDUM") -> "addendum"
      true -> "base"
    end
  end

  defp agenda_language(nil), do: "bilingual"
  defp agenda_language(value) when value in [:fr, "fr"], do: "fr"
  defp agenda_language(value) when value in [:nl, "nl"], do: "nl"
  defp agenda_language(value) when value in [:en, "en"], do: "en"
  defp agenda_language(_value), do: "bilingual"

  defp normalize_eligible(context) do
    normalized = normalize_whitespace(context.text)

    with :ok <- verify_identity(normalized, context) do
      case parse_items(context) do
        {:ok, items} -> {:ok, build_output(context, items)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp verify_identity(normalized, context) do
    date = context.date
    day = date.day

    commune_markers = [
      {"commune_fr", "COMMUNE D'IXELLES"},
      {"commune_nl", "GEMEENTE ELSENE"}
    ]

    heading_markers = [
      "CONSEIL COMMUNAL DU #{day} #{Map.fetch!(@french_months, date.month)} #{date.year}",
      "GEMEENTERAAD VAN #{day} #{Map.fetch!(@dutch_months, date.month)} #{date.year}"
    ]

    footer_date =
      :io_lib.format("~2..0B.~2..0B.~4..0B", [date.day, date.month, date.year]) |> to_string()

    missing_communes =
      for {name, marker} <- commune_markers, not String.contains?(normalized, marker), do: name

    missing =
      missing_communes ++
        if(Enum.any?(heading_markers, &String.contains?(normalized, &1)),
          do: [],
          else: ["meeting_heading"]
        ) ++
        if(String.contains?(normalized, footer_date), do: [], else: ["meeting_date_footer"])

    case missing do
      [] ->
        :ok

      missing ->
        {:error,
         {:normalization_ambiguity,
          %{"contract" => "ixelles-council", "missing_markers" => missing}}}
    end
  end

  defp parse_items(context) do
    pages = pages(context.text)
    total = total_page_count(pages, context.page_count)
    lines = lines_with_pages(pages)
    starts = item_starts(lines)

    cond do
      starts == [] ->
        ambiguity([%{"missing_markers" => ["agenda_items"]}])

      true ->
        results =
          starts
          |> Enum.with_index()
          |> Enum.map(fn {start, position} ->
            stop = Enum.at(starts, position + 1) || length(lines)
            parse_item(lines, pages, total, start, stop, context)
          end)

        case Enum.split_with(results, &match?({:ok, _}, &1)) do
          {oks, []} -> {:ok, Enum.map(oks, fn {:ok, item} -> item end)}
          {_oks, errors} -> ambiguity(Enum.map(errors, fn {:error, reason} -> reason end))
        end
    end
  end

  defp ambiguity(details) do
    {:error,
     {:normalization_ambiguity, %{"contract" => "ixelles-council", "unverified" => details}}}
  end

  defp parse_item(lines, pages, total, start, stop, context) do
    block = Enum.slice(lines, start, stop - start)
    body = Enum.reject(block, fn {_page, line} -> String.trim(line) == "" or footer?(line) end)

    with {:ok, number} <- item_number(lines, start),
         {:ok, split} <- split_index(body),
         :ok <- verify_french_segment(body, split),
         {:ok, wording} <- french_wording(body, split),
         :ok <- verify_item_excerpt(wording, body, split, pages) do
      {:ok, item(number, wording, body, split, pages, total, context)}
    else
      {:error, _reason} = error -> error
    end
  end

  # Fail-closed content-safety guard. The split point alone can place Dutch
  # translation lines in the French slot, and the excerpt check would still pass
  # because the emitted excerpt is the same string. The French segment must
  # therefore be provably French-dominant under the same curated marker lexicon:
  # strictly more French markers than Dutch markers. A Dutch-dominant or
  # balanced segment is an ambiguity that a reviewer must resolve.
  defp verify_french_segment(body, split) do
    body
    |> Enum.take(split)
    |> Enum.map(&elem(&1, 1))
    |> marker_balance()
    |> case do
      balance when balance > 0 ->
        :ok

      balance when balance < 0 ->
        {:error,
         %{
           "reason" => "agenda_item_french_segment_is_dutch_dominant",
           "marker_balance" => balance
         }}

      balance ->
        {:error,
         %{
           "reason" => "agenda_item_french_segment_not_french_dominant",
           "marker_balance" => balance
         }}
    end
  end

  defp marker_balance(lines),
    do: Enum.reduce(lines, 0, fn line, acc -> acc + line_score(line) end)

  defp item_number(lines, start) do
    {_page, line} = Enum.at(lines, start)

    case Regex.run(@item_start, line) do
      [_, number, _rest] -> {:ok, number}
      _other -> {:error, %{"reason" => "agenda_item_number_unreadable"}}
    end
  end

  defp split_index(body) do
    lines = Enum.map(body, fn {_page, line} -> line end)
    scores = Enum.map(lines, &line_score/1)
    count = length(scores)

    if count < 2 do
      {:error, %{"reason" => "agenda_item_paragraph_unreadable"}}
    else
      candidates = Enum.to_list(1..(count - 1))

      best =
        Enum.max_by(candidates, fn index ->
          Enum.sum(Enum.take(scores, index)) - Enum.sum(Enum.drop(scores, index))
        end)

      split = advance_to_dutch(scores, best, count)

      if split >= count,
        do: {:error, %{"reason" => "agenda_item_has_no_dutch_translation"}},
        else: {:ok, split}
    end
  end

  defp advance_to_dutch(scores, index, count) when index < count do
    if Enum.at(scores, index) < 0, do: index, else: advance_to_dutch(scores, index + 1, count)
  end

  defp advance_to_dutch(_scores, index, _count), do: index

  defp line_score(line) do
    line
    |> String.downcase()
    |> then(&Regex.scan(~r/[0-9\p{L}'’]+/u, &1))
    |> List.flatten()
    |> Enum.reduce(0, fn token, acc ->
      cond do
        MapSet.member?(@french_markers, token) -> acc + 1
        MapSet.member?(@dutch_markers, token) -> acc - 1
        true -> acc
      end
    end)
  end

  defp french_wording(body, split) do
    french_lines = Enum.take(body, split)
    [{_page, first_line} | rest] = french_lines

    wording =
      [Regex.replace(@item_prefix, first_line, "") | Enum.map(rest, &elem(&1, 1))]
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")
      |> normalize_whitespace()

    if wording == "",
      do: {:error, %{"reason" => "agenda_item_wording_empty"}},
      else: {:ok, wording}
  end

  defp verify_item_excerpt(wording, body, split, pages) do
    page_indexes =
      body
      |> Enum.take(split)
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()

    slice =
      page_indexes
      |> Enum.map(&Enum.at(pages, &1 - 1))
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    case verify_excerpt(wording, slice) do
      :ok -> :ok
      {:error, :excerpt_not_found} -> {:error, %{"reason" => "agenda_item_excerpt_not_found"}}
    end
  end

  defp item(number, wording, body, split, _pages, total, context) do
    french_pages =
      body |> Enum.take(split) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    base = %{
      "item_number" => number,
      "authoritative_identifier" => number,
      "source_wording" => wording
    }

    if proposal?(wording) do
      Map.put(base, "proposals", [
        %{
          "text" => wording,
          "evidence" => %{
            "claim" => "proposal",
            "excerpt" => wording,
            "location" => location(context.kind, number, french_pages, total),
            "applicable_from" => Date.to_iso8601(context.date)
          }
        }
      ])
    else
      base
    end
  end

  defp proposal?(wording) do
    downcased = String.downcase(wording)

    not Enum.any?(@non_action_prefixes, &String.starts_with?(downcased, &1))
  end

  defp location(kind, number, pages, total) do
    label =
      case kind do
        "complementary" -> "Ordre du jour complémentaire"
        "supplement" -> "Supplément à l'ordre du jour"
        "addendum" -> "Addendum à l'ordre du jour"
        _other -> "Ordre du jour"
      end

    case pages do
      [page] -> "#{label}, point #{number}, page #{page}/#{total}"
      [first | _rest] -> "#{label}, point #{number}, pages #{first}-#{List.last(pages)}/#{total}"
    end
  end

  defp build_output(context, items) do
    %{
      "meeting_identifier" => context.meeting_identifier,
      "scheduled_on" => Date.to_iso8601(context.date),
      "agenda" => %{"kind" => context.kind, "language" => context.language},
      "items" => items
    }
  end

  defp pages(text) do
    case text |> String.split("\f") |> Enum.reject(&(&1 == "")) do
      [] -> [text]
      pages -> pages
    end
  end

  defp total_page_count(pages, page_count) do
    if is_integer(page_count) and page_count > 0,
      do: max(page_count, length(pages)),
      else: length(pages)
  end

  defp lines_with_pages(pages) do
    pages
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {page, index} ->
      page |> String.split("\n") |> Enum.map(fn line -> {index, line} end)
    end)
  end

  defp item_starts(lines) do
    lines
    |> Enum.with_index()
    |> Enum.filter(fn {{_page, line}, _index} -> Regex.match?(@item_start, line) end)
    |> Enum.map(fn {_entry, index} -> index end)
  end

  defp footer?(line), do: Regex.match?(@footer, line)

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: :error

  defp normalize_whitespace(text), do: String.replace(text, ~r/\s+/u, " ")
end
