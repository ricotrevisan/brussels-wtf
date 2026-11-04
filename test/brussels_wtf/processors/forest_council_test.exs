defmodule BrusselsWtf.Processors.ForestCouncilTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Processors.ForestCouncil

  alias BrusselsWtf.ForestAgendaFixture, as: Fixture

  defp agenda_text, do: Fixture.text()

  defp input(overrides \\ %{}) do
    Map.merge(
      %{
        "commune_slug" => "forest",
        "origin_url" => "https://forest.brussels/agenda.pdf",
        "role" => "agenda",
        "language" => "bilingual",
        "meeting_identifier" => "2026-09-22",
        "scheduled_on" => "2026-09-22",
        "sha256" => String.duplicate("a", 64),
        "page_count" => 4,
        "text" => agenda_text()
      },
      overrides
    )
  end

  defp ambiguity(result) do
    assert {:error, {:normalization_ambiguity, %{"contract" => "forest-council"} = details}} =
             result

    details
  end

  test "normalizes the real layout into cited proposals and never a decision" do
    assert {:ok, normalized} = ForestCouncil.normalize(input())

    assert normalized["meeting_identifier"] == "2026-09-22"
    assert normalized["scheduled_on"] == "2026-09-22"
    assert normalized["agenda"] == %{"kind" => "base", "language" => "bilingual"}
    assert normalized["restates_agenda"] == true

    items = normalized["items"]
    assert Enum.map(items, & &1["item_number"]) == ~w(1 2 3 4 5 6)
    assert hd(items)["authoritative_identifier"] == "forest-2026-09-22-1"
    refute Enum.any?(items, &Map.has_key?(&1, "decisions"))

    assert hd(hd(items)["proposals"])["evidence"] == %{
             "claim" => "proposal",
             "excerpt" => "Assemblées - Mandats (Forest Centre Culturel) - Remplacement.",
             "location" => "Ordre du jour, point 1, page 1/4",
             "applicable_from" => "2026-09-22"
           }
  end

  test "French wording that crosses a page keeps the whole paragraph and cites both pages" do
    {:ok, %{"items" => items}} = ForestCouncil.normalize(input())
    [%{"text" => text, "evidence" => evidence}] = Enum.at(items, 1)["proposals"]

    assert String.starts_with?(text, "Revitalisation des quartiers")

    assert String.ends_with?(
             text,
             "de la rédaction d’un rapport d’évaluation finale de gestion des risques – Budget complémentaire – Prise pour information."
           )

    refute text =~ "Conseil communal -"
    refute text =~ "Heropleving"
    assert evidence["location"] == "Ordre du jour, point 2, pages 1-2/4"
  end

  test "Dutch that starts or continues on the next page never reaches the French wording" do
    {:ok, %{"items" => items}} = ForestCouncil.normalize(input())

    assert Enum.at(items, 2)["source_wording"] ==
             "Marchés publics – MP-2026-T-023 – Extension du remplacement de la fibre optique – Information."

    assert hd(Enum.at(items, 2)["proposals"])["evidence"]["location"] ==
             "Ordre du jour, point 3, page 2/4"

    assert Enum.at(items, 3)["source_wording"] ==
             "Voirie – Centrale d'achat – Adhésion à la centrale d'achat de l'Intercommunale."

    assert hd(Enum.at(items, 3)["proposals"])["evidence"]["location"] ==
             "Ordre du jour, point 4, page 3/4"
  end

  test "headings and annex counts stay out of every wording" do
    {:ok, %{"items" => items}} = ForestCouncil.normalize(input())

    for item <- items do
      refute item["source_wording"] =~ "TRAVAUX PUBLICS"
      refute item["source_wording"] =~ "annexes"
    end
  end

  test "items answered by a voted acknowledgement stay proposals with their official wording" do
    {:ok, %{"items" => items}} = ForestCouncil.normalize(input())

    assert [%{"text" => text}] = Enum.at(items, 2)["proposals"]
    assert String.ends_with?(text, "– Information.")
  end

  test "interpellations and oral questions keep their item but carry no proposal" do
    {:ok, %{"items" => items}} = ForestCouncil.normalize(input())

    for number <- ["5", "6"] do
      item = Enum.find(items, &(&1["item_number"] == number))
      assert item["source_wording"] != ""
      refute Map.has_key?(item, "proposals")
    end
  end

  test "every emitted excerpt occurs on its cited pages once the running footer is removed" do
    {:ok, %{"items" => items}} = ForestCouncil.normalize(input())
    pages = String.split(agenda_text(), "\f", trim: true)

    for %{"proposals" => [%{"text" => text, "evidence" => evidence}]} <- items do
      assert evidence["excerpt"] == text
      assert ForestCouncil.excerpt_on_cited_pages?(evidence, pages)
    end
  end

  test "excerpt verification rejects a page the excerpt is not on" do
    pages = String.split(agenda_text(), "\f", trim: true)

    refute ForestCouncil.excerpt_on_cited_pages?(
             %{
               "excerpt" => "Assemblées - Mandats (Forest Centre Culturel) - Remplacement.",
               "location" => "Ordre du jour, point 1, page 2/4"
             },
             pages
           )

    refute ForestCouncil.excerpt_on_cited_pages?(
             %{"excerpt" => "Assemblées", "location" => "unreadable"},
             pages
           )
  end

  test "a complementary agenda is labelled from its own heading and footer" do
    text =
      agenda_text()
      |> String.replace("ORDRE DU JOUR\n", "ORDRE DU JOUR COMPLÉMENTAIRE\n")
      |> String.replace("AGENDA\n", "AANVULLENDE AGENDA\n")
      |> String.replace("- Ordre du jour public", "- Ordre du jour complémentaire public")
      |> String.replace("- Openbare agenda", "- Aanvullende openbare agenda")

    {:ok, normalized} =
      ForestCouncil.normalize(input(%{"role" => "complementary_agenda", "text" => text}))

    assert normalized["agenda"]["kind"] == "complementary"

    assert hd(hd(normalized["items"])["proposals"])["evidence"]["location"] ==
             "Ordre du jour complémentaire, point 1, page 1/4"
  end

  test "a locator role that disagrees with the document heading opens a review" do
    details = ambiguity(ForestCouncil.normalize(input(%{"role" => "complementary_agenda"})))
    assert details["reason"] == "agenda_kind_mismatch"
  end

  test "a Collège agenda behind a council locator never becomes a council meeting" do
    # Real finding: Forest's 23 June 2026 "complementary agenda" locator serves
    # the Collège agenda of 25 June 2026.
    text =
      agenda_text()
      |> String.replace(
        "CONSEIL COMMUNAL DU 22 SEPTEMBRE 2026",
        "COLLÈGE DES BOURGMESTRE ET ECHEVINS DU 22 SEPTEMBRE 2026"
      )
      |> String.replace(
        "GEMEENTERAAD VAN 22 SEPTEMBER 2026",
        "COLLEGE VAN BURGEMEESTER EN SCHEPENEN VAN 22 SEPTEMBER 2026"
      )

    details = ambiguity(ForestCouncil.normalize(input(%{"text" => text})))
    assert "meeting_heading_fr" in details["missing_markers"]
    assert "meeting_heading_nl" in details["missing_markers"]
  end

  test "a document for another date, commune or a closed session opens a review" do
    other_date = input(%{"meeting_identifier" => "2026-10-13", "scheduled_on" => "2026-10-13"})

    assert "meeting_heading_fr" in ambiguity(ForestCouncil.normalize(other_date))[
             "missing_markers"
           ]

    other_commune =
      input(%{
        "text" => String.replace(agenda_text(), "COMMUNALE DE FOREST", "COMMUNALE D'UCCLE")
      })

    assert "commune_fr" in ambiguity(ForestCouncil.normalize(other_commune))["missing_markers"]

    closed =
      input(%{
        "text" =>
          String.replace(
            agenda_text(),
            "SÉANCE PUBLIQUE - OPENBARE ZITTING",
            "SÉANCE À HUIS CLOS - BESLOTEN ZITTING"
          )
      })

    assert ambiguity(ForestCouncil.normalize(closed))["reason"] == "not_a_public_session_agenda"
  end

  test "a missing page, a wrong page total or an unnumbered footer opens a review" do
    [first, _second, third, fourth] = String.split(agenda_text(), "\f", trim: true)
    missing_page = Enum.join([first, third, fourth], "\f")

    assert ambiguity(ForestCouncil.normalize(input(%{"text" => missing_page})))["reason"] ==
             "page_footer_mismatch"

    assert ambiguity(ForestCouncil.normalize(input(%{"page_count" => 5})))["reason"] ==
             "page_footer_mismatch"

    no_footer = String.replace(agenda_text(), "3/4", "")

    assert ambiguity(ForestCouncil.normalize(input(%{"text" => no_footer})))["reason"] ==
             "page_footer_mismatch"
  end

  test "a skipped or repeated item number opens a review" do
    text = String.replace(agenda_text(), "\n    3        Marchés", "\n    7        Marchés")

    assert ambiguity(ForestCouncil.normalize(input(%{"text" => text})))["reason"] ==
             "item_numbers_not_contiguous"
  end

  test "a document with no numbered item opens a review" do
    text = Fixture.header() <> Fixture.footer(1, 1)

    assert ambiguity(ForestCouncil.normalize(input(%{"text" => text, "page_count" => 1})))[
             "reason"
           ] == "item_numbers_not_contiguous"
  end

  describe "item-level ambiguity fails the whole document" do
    defp unverified(old, new) do
      text = String.replace(agenda_text(), old, new)
      assert text != agenda_text()
      ambiguity(ForestCouncil.normalize(input(%{"text" => text})))["unverified"]
    end

    test "an item without a Dutch translation" do
      assert [%{"item" => "1", "reason" => "agenda_item_paragraphs_unreadable"}] =
               unverified(
                 "\n             Bestuursorganen - Mandaten (Forest Centre Culturel) - Vervanging.\n",
                 ""
               )
    end

    test "a paragraph the layout cannot assign to one language" do
      assert [%{"item" => "1", "reason" => "agenda_item_paragraphs_unreadable"}] =
               unverified(
                 "(Forest Centre Culturel) - Vervanging.\n",
                 "(Forest Centre Culturel) - Vervanging.\n\n             Bijkomende alinea.\n"
               )
    end

    test "swapped French and Dutch paragraphs" do
      text =
        agenda_text()
        |> String.replace("Assemblées - Mandats (Forest Centre Culturel) - Remplacement.", "@@")
        |> String.replace(
          "Bestuursorganen - Mandaten (Forest Centre Culturel) - Vervanging.",
          "Assemblées - Mandats (Forest Centre Culturel) - Remplacement."
        )
        |> String.replace(
          "@@",
          "Bestuursorganen - Mandaten (Forest Centre Culturel) - Vervanging."
        )

      assert [%{"item" => "1", "reason" => "agenda_item_language_unverified"}] =
               ambiguity(ForestCouncil.normalize(input(%{"text" => text})))["unverified"]
    end

    test "two paragraphs with no language evidence" do
      text =
        agenda_text()
        |> String.replace(
          "Assemblées - Mandats (Forest Centre Culturel) - Remplacement.",
          "Forest Centre Culturel."
        )
        |> String.replace(
          "Bestuursorganen - Mandaten (Forest Centre Culturel) - Vervanging.",
          "Forest Centre Culturel."
        )

      assert [%{"item" => "1", "reason" => "agenda_item_language_unverified"}] =
               ambiguity(ForestCouncil.normalize(input(%{"text" => text})))["unverified"]
    end

    test "body text after an annex count or a section heading" do
      assert [%{"item" => "2", "reason" => "agenda_item_paragraphs_unreadable"}] =
               unverified(
                 "             4 annexes / 4 bijlagen\n",
                 "             4 annexes / 4 bijlagen\n             Tekst na de bijlagen.\n"
               )
    end
  end

  describe "the commune normalizer stays bounded" do
    test "other document roles, communes and missing identity stay unavailable" do
      for overrides <- [
            %{"role" => "explanatory_notes"},
            %{"role" => "motion"},
            %{"role" => "minutes"},
            %{"role" => nil},
            %{"commune_slug" => "uccle"},
            %{"meeting_identifier" => nil},
            %{"scheduled_on" => "not-a-date"},
            %{"text" => "  "},
            %{"meeting_identifier" => "2026-10-13"}
          ] do
        assert ForestCouncil.normalize(input(overrides)) == {:error, :processor_unimplemented}
      end

      assert ForestCouncil.normalize(nil) == {:error, :processor_unimplemented}
    end

    test "a meeting before the replay floor stays unavailable, so nothing historical replays" do
      assert ForestCouncil.normalize(
               input(%{"meeting_identifier" => "2026-08-31", "scheduled_on" => "2026-08-31"})
             ) == {:error, :processor_unimplemented}
    end

    test "a meeting in the recorded corpus opens a review and keeps its sealed page" do
      details =
        ambiguity(
          ForestCouncil.normalize(
            input(%{"meeting_identifier" => "2026-09-01", "scheduled_on" => "2026-09-01"})
          )
        )

      assert details["reason"] == "recorded_corpus_meeting"
    end
  end
end
