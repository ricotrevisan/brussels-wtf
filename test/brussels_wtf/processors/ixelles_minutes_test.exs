defmodule BrusselsWtf.Processors.IxellesMinutesTest do
  use ExUnit.Case, async: true

  import BrusselsWtf.Test.IxellesMinutesFixture

  alias BrusselsWtf.Processors.IxellesMinutes

  defp input(text, overrides) do
    Map.merge(
      %{
        "commune_slug" => "ixelles",
        "role" => "minutes",
        "meeting_identifier" => "266",
        "scheduled_on" => "2026-05-21",
        "page_count" => 158,
        "text" => text,
        "agenda_items" => []
      },
      overrides
    )
  end

  defp agenda_row(number, wording) do
    %{
      "item_number" => to_string(number),
      "authoritative_identifier" => to_string(number),
      "source_wording" => wording
    }
  end

  defp point_with(number, wording, outcome),
    do: Map.merge(%{number: number, wording: wording}, outcome)

  defp normalize!(points, agenda_items) do
    assert {:ok, normalized} =
             points
             |> document()
             |> input(%{"agenda_items" => agenda_items})
             |> IxellesMinutes.normalize()

    normalized
  end

  test "an approved point on the agenda keeps its identity and records the printed vote" do
    wording = "Budget 2026. Approbation."

    normalized =
      normalize!([point_with(1, wording, approved(35))], [agenda_row(1, wording)])

    assert normalized["meeting_identifier"] == "266"
    assert normalized["scheduled_on"] == "2026-05-21"
    assert normalized["agenda"]["kind"] == "final"

    assert [item] = normalized["items"]
    assert item["item_number"] == "1"
    assert item["authoritative_identifier"] == "1"
    assert item["source_wording"] == wording
    refute Map.has_key?(item, "proposals")

    assert [decision] = item["decisions"]
    assert decision["disposition"] == "approved"
    assert decision["statement"] == "Le Conseil approuve."
    assert decision["evidence"]["excerpt"] == "Le Conseil approuve."

    assert decision["evidence"]["location"] ==
             "Procès-verbal, point 21.05.2026/A/0001, page 1/158"

    assert decision["evidence"]["applicable_from"] == "2026-05-21"

    assert decision["vote"]["for"] == 35
    assert decision["vote"]["against"] == 0
    assert decision["vote"]["abstentions"] == 0
    assert decision["vote"]["evidence"]["excerpt"] == "35 votants : 35 votes positifs."
  end

  test "a printed rejection and its contested tally are recorded verbatim" do
    wording = "Proposition de motion relative à la gestion de l'asbl."

    outcome = %{
      lines: [
        "Le point est rejeté.",
        "39 votants : 15 votes positifs, 24 votes négatifs.",
        "Non : Membre Un, Membre Deux."
      ],
      dutch_lines: [
        "Het punt wordt verworpen.",
        "39 stemmers : 15 positieve stemmen, 24 negatieve stemmen."
      ]
    }

    normalized = normalize!([point_with(1, wording, outcome)], [agenda_row(1, wording)])

    assert [%{"decisions" => [decision]}] = normalized["items"]
    assert decision["disposition"] == "rejected"
    assert decision["vote"]["for"] == 15
    assert decision["vote"]["against"] == 24
    assert normalized["minutes_receipt"]["contested"] == 1
  end

  test "a postponed votable point is recorded without a vote" do
    wording = "Projet WePulse. Approbation."

    outcome = %{
      lines: ["Le point est reporté."],
      dutch_lines: ["Het punt wordt verdaagd."]
    }

    assert [%{"decisions" => [decision]}] =
             normalize!([point_with(1, wording, outcome)], [agenda_row(1, wording)])["items"]

    assert decision["disposition"] == "postponed"
    refute Map.has_key?(decision, "vote")
  end

  test "a secret ballot with per-candidate counts approves without a single tally" do
    wording = "Remplacement des représentants communaux. Désignation."

    outcome = %{
      lines: [
        "Le Conseil approuve.",
        "Décision prise par scrutin secret: 38 votants;",
        "",
        "Pour M. Un: 29 bulletins portent la mention OUI, 5 bulletins portent",
        "la mention NON et 4 abstentions;"
      ],
      dutch_lines: [
        "De Raad keurt goed.",
        "Beslissing genomen bij geheime stemming: 38 stemmers;"
      ]
    }

    assert [%{"decisions" => [decision]}] =
             normalize!([point_with(1, wording, outcome)], [agenda_row(1, wording)])["items"]

    assert decision["disposition"] == "approved"
    refute Map.has_key?(decision, "vote")
  end

  test "a secret ballot with one printed tally records that tally" do
    wording = "Asbl. Désignation d'une déléguée."

    outcome = %{
      lines: [
        "Décision prise par scrutin secret. Le Conseil approuve.",
        "38 votants : 30 votes positifs, 5 votes négatifs, 3 abstentions."
      ],
      dutch_lines: [
        "Besluit bij geheime stemming. De Raad keurt goed.",
        "38 stemmers : 30 positieve stemmen, 5 negatieve stemmen, 3 onthoudingen."
      ]
    }

    assert [%{"decisions" => [decision]}] =
             normalize!([point_with(1, wording, outcome)], [agenda_row(1, wording)])["items"]

    assert decision["statement"] == "Décision prise par scrutin secret. Le Conseil approuve."

    assert {decision["vote"]["for"], decision["vote"]["against"], decision["vote"]["abstentions"]} ==
             {30, 5, 3}
  end

  test "a votable point the council only noted is an explicit other outcome" do
    wording = "Rapport d'évaluation du Conseil Consultatif."

    outcome = %{
      lines: ["Le Conseil prend connaissance."],
      dutch_lines: ["De Raad neemt kennis."]
    }

    assert [%{"decisions" => [decision]}] =
             normalize!([point_with(1, wording, outcome)], [agenda_row(1, wording)])["items"]

    assert decision["disposition"] == "other"
    assert decision["statement"] == "Le Conseil prend connaissance."
  end

  describe "the receipt" do
    test "counts decided, non-votable and unmatched points so every point is accounted for" do
      budget = "Budget 2026. Approbation."
      question = "Question orale de M. Deux, Conseiller communal, relative au parc."
      silent = "Compte de l'exercice 2025. Désignation."

      normalized =
        normalize!(
          [
            point_with(1, budget, approved(35)),
            point_with(2, question, %{
              lines: ["Le point est reporté."],
              dutch_lines: ["Het punt wordt verdaagd."]
            }),
            point_with(3, silent, %{lines: ["LE CONSEIL,", "DECIDE", "d'approuver."]})
          ],
          [agenda_row(1, budget), agenda_row(2, question), agenda_row(3, silent)]
        )

      assert [%{"authoritative_identifier" => "1"}] = normalized["items"]

      assert normalized["minutes_receipt"] == %{
               "points" => 3,
               "decided" => 1,
               "non_votable" => 1,
               "minutes_only" => 0,
               "contested" => 0,
               "unmatched" => [
                 %{"identifier" => "21.05.2026/A/0003", "reason" => "no_explicit_outcome"}
               ]
             }
    end
  end

  describe "unmatched points stay unknown" do
    @wording "Budget 2026. Approbation."

    defp unmatched_reason(outcome, agenda_wording \\ @wording) do
      keeper = "Compte de l'exercice 2025. Désignation."

      normalized =
        normalize!(
          [point_with(1, @wording, outcome), point_with(2, keeper, approved(35))],
          [agenda_row(1, agenda_wording), agenda_row(2, keeper)]
        )

      assert [%{"authoritative_identifier" => "2"}] = normalized["items"]
      assert [%{"reason" => reason}] = normalized["minutes_receipt"]["unmatched"]
      reason
    end

    test "when the DECIDE text exists but no outcome line was printed" do
      assert unmatched_reason(%{lines: ["DECIDE", "d'approuver le budget."]}) ==
               "no_explicit_outcome"
    end

    test "when the outcome phrase is outside the observed vocabulary" do
      assert unmatched_reason(%{
               lines: ["Le point est retiré."],
               dutch_lines: ["Het punt wordt ingetrokken."]
             }) == "no_explicit_outcome"
    end

    test "when the agenda wording at that number differs" do
      assert unmatched_reason(approved(35), "Budget 2027. Approbation.") == "wording_differs"
    end

    test "when French and Dutch outcomes disagree" do
      assert unmatched_reason(%{
               lines: ["Le Conseil approuve."],
               dutch_lines: ["Het punt wordt verworpen."]
             }) == "french_dutch_outcome_conflict"
    end

    test "when the Dutch outcome is missing" do
      assert unmatched_reason(%{lines: ["Le Conseil approuve."]}) ==
               "french_dutch_outcome_conflict"
    end

    test "when two outcomes are printed" do
      assert unmatched_reason(%{
               lines: ["Le Conseil approuve.", "", "Le point est rejeté."],
               dutch_lines: ["De Raad keurt goed."]
             }) == "multiple_outcomes"
    end

    test "when the printed tally does not add up" do
      assert unmatched_reason(%{
               lines: ["Le Conseil approuve.", "38 votants : 30 votes positifs."],
               dutch_lines: ["De Raad keurt goed.", "38 stemmers : 30 positieve stemmen."]
             }) == "unreadable_tally"
    end

    test "when French and Dutch tallies disagree" do
      assert unmatched_reason(%{
               lines: ["Le Conseil approuve.", "35 votants : 35 votes positifs."],
               dutch_lines: ["De Raad keurt goed.", "34 stemmers : 34 positieve stemmen."]
             }) == "french_dutch_tally_conflict"
    end

    test "when the tally contradicts the printed outcome" do
      assert unmatched_reason(%{
               lines: [
                 "Le Conseil approuve.",
                 "39 votants : 15 votes positifs, 24 votes négatifs."
               ],
               dutch_lines: [
                 "De Raad keurt goed.",
                 "39 stemmers : 15 positieve stemmen, 24 negatieve stemmen."
               ]
             }) == "tally_contradicts_outcome"
    end

    test "when a non-votable point claims a terminal outcome" do
      question = "Question orale de M. Deux, Conseiller communal, relative au parc."
      keeper = "Compte de l'exercice 2025. Désignation."

      normalized =
        normalize!(
          [point_with(1, question, approved(35)), point_with(2, keeper, approved(35))],
          [agenda_row(1, question), agenda_row(2, keeper)]
        )

      assert [%{"reason" => "non_votable_with_terminal_outcome"}] =
               normalized["minutes_receipt"]["unmatched"]
    end
  end

  describe "item identity" do
    test "typography differences at the same number do not break identity" do
      normalized =
        normalize!(
          [
            point_with(
              1,
              "Concours « Big Talent » – Approbation du règlement.et de la Politique.",
              approved(35)
            ),
            point_with(2, "Plan relatif au sans- abrisme.", approved(35))
          ],
          [
            agenda_row(
              1,
              "Concours « Big Talent » – Approbation du règlement et de la Politique."
            ),
            agenda_row(2, "Plan relatif au sans-abrisme.")
          ]
        )

      assert normalized["minutes_receipt"]["unmatched"] == []
      assert Enum.map(normalized["items"], & &1["authoritative_identifier"]) == ["1", "2"]
    end

    test "an agenda wording holding the start of the printed Dutch title keeps its identity" do
      french = "Convention de transaction avec la société pour un montant de 51.365,05 EUR."
      dutch = "Dadingsovereenkomst tussen de gemeente en de vennootschap voor een bedrag."

      normalized =
        normalize!(
          [
            point_with(1, french, approved(35))
            |> Map.put(:dutch_title, dutch)
          ],
          [agenda_row(1, french <> " Dadingsovereenkomst tussen de gemeente")]
        )

      assert normalized["minutes_receipt"]["unmatched"] == []
      assert [%{"source_wording" => ^french}] = normalized["items"]
    end

    test "an agenda wording that says more in French does not match a shortened title" do
      minutes = "Asbl. Prise d'acte de la démission de deux administrateurs."
      agenda = "Asbl. Prise d'acte de la démission de deux administrateurs et désignation."
      keeper = "Compte de l'exercice 2025. Désignation."

      normalized =
        normalize!(
          [point_with(1, minutes, approved(35)), point_with(2, keeper, approved(35))],
          [agenda_row(1, agenda), agenda_row(2, keeper)]
        )

      assert [%{"reason" => "wording_differs"}] = normalized["minutes_receipt"]["unmatched"]
    end

    test "a point absent from the agenda gets the printed dated identifier and no proposal" do
      normalized = normalize!([point_with(1, "Motion déposée en séance.", approved(35))], [])

      assert [item] = normalized["items"]
      assert item["authoritative_identifier"] == "21.05.2026/A/0001"
      assert item["item_number"] == "1"
      refute Map.has_key?(item, "proposals")
      assert normalized["minutes_receipt"]["minutes_only"] == 1
    end

    test "a re-read keeps the identity of a dated row it already created" do
      wording = "Motion déposée en séance."

      normalized =
        normalize!(
          [point_with(1, wording, approved(35))],
          [
            %{
              "item_number" => "1",
              "authoritative_identifier" => "21.05.2026/A/0001",
              "source_wording" => wording
            }
          ]
        )

      assert [%{"authoritative_identifier" => "21.05.2026/A/0001"}] = normalized["items"]
    end
  end

  describe "the observed page layout" do
    test "a heading split by a page footer is one wording, and the outcome cites its page" do
      date = ~D[2026-05-21]
      wording = "Marché public de travaux concernant le remplacement des tentures. Approbation."

      text =
        header(date) <>
          "    #{identifier(date, 1)}             Marché public de travaux concernant le remplacement des\n\n" <>
          footer(date, 1, 2) <>
          "\f" <>
          String.duplicate(" ", 34) <>
          "tentures. Approbation.\n\n" <>
          String.duplicate(" ", 34) <>
          "Le Conseil approuve.\n" <>
          String.duplicate(" ", 34) <>
          "35 votants : 35 votes positifs.\n\n" <>
          String.duplicate(" ", 34) <>
          "De Raad keurt goed.\n" <>
          String.duplicate(" ", 34) <>
          "35 stemmers : 35 positieve stemmen.\n\n" <>
          "                 Levée de la séance à 21:15\n" <>
          footer(date, 2, 2) <> "\f"

      assert {:ok, normalized} =
               text
               |> input(%{"agenda_items" => [agenda_row(1, wording)], "page_count" => 2})
               |> IxellesMinutes.normalize()

      assert [%{"source_wording" => ^wording, "decisions" => [decision]}] = normalized["items"]

      assert decision["evidence"]["location"] ==
               "Procès-verbal, point 21.05.2026/A/0001, page 2/2"
    end

    test "a blank page keeps the printed page number of a later outcome" do
      date = ~D[2026-05-21]
      wording = "Budget 2026. Approbation."

      text =
        header(date) <>
          footer(date, 1, 3) <>
          "\f\n\f" <>
          point(Map.merge(%{number: 1, wording: wording}, approved(35)), date) <>
          "                 Levée de la séance à 21:15\n" <>
          footer(date, 3, 3) <> "\f"

      assert {:ok, normalized} =
               text
               |> input(%{"agenda_items" => [agenda_row(1, wording)], "page_count" => 3})
               |> IxellesMinutes.normalize()

      assert [%{"decisions" => [decision]}] = normalized["items"]

      assert decision["evidence"]["location"] ==
               "Procès-verbal, point 21.05.2026/A/0001, page 3/3"
    end

    test "a heading on the first line of a page is still a heading" do
      date = ~D[2026-05-21]
      first = "Budget 2026. Approbation."
      second = "Compte de l'exercice 2025. Désignation."

      text =
        header(date) <>
          point(Map.merge(%{number: 1, wording: first}, approved(35)), date) <>
          footer(date, 1, 2) <>
          "\f" <>
          point(Map.merge(%{number: 2, wording: second}, approved(35)), date) <>
          "                 Levée de la séance à 21:15\n" <>
          footer(date, 2, 2) <> "\f"

      assert {:ok, normalized} =
               text
               |> input(%{"agenda_items" => [agenda_row(1, first), agenda_row(2, second)]})
               |> IxellesMinutes.normalize()

      assert length(normalized["items"]) == 2
    end

    test "a cited earlier decision inside a body is not a heading" do
      wording = "Budget 2026. Approbation."

      outcome =
        Map.update!(approved(35), :lines, fn lines ->
          ["(réf. 26.03.2002/A/076) décidant le plan lumière" | lines]
        end)

      normalized = normalize!([point_with(1, wording, outcome)], [agenda_row(1, wording)])
      assert normalized["minutes_receipt"]["points"] == 1
    end
  end

  describe "the whole document fails closed" do
    @approved %{number: 1, wording: "Budget 2026. Approbation."}

    defp approved_document, do: document([Map.merge(@approved, approved(35))])

    defp ambiguity(text, overrides \\ %{}) do
      assert {:error, {:normalization_ambiguity, details}} =
               text |> input(overrides) |> IxellesMinutes.normalize()

      assert details["contract"] == "ixelles-minutes"
      details
    end

    test "when the commune heading is missing" do
      text = String.replace(approved_document(), "COMMUNE D'IXELLES", "COMMUNE DE FOREST")
      assert ambiguity(text)["missing_markers"] == ["commune_fr"]
    end

    test "when the document belongs to another meeting date" do
      details = ambiguity(approved_document(), %{"scheduled_on" => "2026-05-22"})
      assert "meeting_heading" in details["missing_markers"]
      assert "public_minutes_footer" in details["missing_markers"]
    end

    test "when a heading carries another meeting's date" do
      text =
        document([
          Map.merge(@approved, approved(35)),
          %{number: 2, identifier: "22.05.2026/A/0002", wording: "Autre point."}
        ])

      assert ambiguity(text)["reason"] == "heading_date_conflict"
    end

    test "when a heading uses an unobserved series" do
      text =
        document([
          Map.merge(@approved, approved(35)),
          %{number: 2, identifier: "21.05.2026/B/0002", wording: "Point à huis clos."}
        ])

      assert ambiguity(text)["reason"] == "unobserved_heading_series"
    end

    test "when numbering has a gap" do
      text =
        document([
          Map.merge(@approved, approved(35)),
          %{number: 3, wording: "Compte de l'exercice."}
        ])

      assert ambiguity(text)["reason"] == "point_numbering_not_contiguous"
    end

    test "when numbering repeats" do
      text =
        document([
          Map.merge(@approved, approved(35)),
          Map.merge(@approved, approved(35))
        ])

      assert ambiguity(text)["reason"] == "point_numbering_not_contiguous"
    end

    test "when the closing line is missing, so the text may be truncated" do
      text = document([Map.merge(@approved, approved(35))], closing: false)
      assert ambiguity(text)["reason"] == "session_close_missing"
    end

    test "when no point is decided" do
      text =
        document([
          %{
            number: 1,
            wording: "Question orale de M. Deux, Conseiller communal, relative au parc.",
            lines: ["Le Conseil prend acte et répond en séance."],
            dutch_lines: ["De Raad neemt akte en antwoordt in zitting."]
          }
        ])

      assert ambiguity(text)["reason"] == "minutes_without_decisions"
    end
  end

  describe "eligibility" do
    defp unimplemented?(overrides, text \\ nil) do
      text = text || document([%{number: 1, wording: "Budget."}])
      IxellesMinutes.normalize(input(text, overrides)) == {:error, :processor_unimplemented}
    end

    test "only Ixelles minutes of the observed 2026 layout are read" do
      assert unimplemented?(%{"commune_slug" => "forest"})
      assert unimplemented?(%{"role" => "agenda"})
      assert unimplemented?(%{"scheduled_on" => "2025-12-31"})
      assert unimplemented?(%{"meeting_identifier" => nil})
      assert unimplemented?(%{"scheduled_on" => nil})
      assert unimplemented?(%{}, "ORDRE DU JOUR")
      assert IxellesMinutes.normalize(:not_a_map) == {:error, :processor_unimplemented}
    end
  end
end
