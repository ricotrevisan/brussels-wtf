defmodule BrusselsWtf.Processors.UccleCouncilTest do
  @moduledoc """
  Layout contract for the Uccle agenda normalizer, on minimal excerpts of real agendas.

  See `test/support/fixtures/uccle/agendas/README.md` for what the excerpts are, and
  `docs/research/2026-11-03-uccle-agenda-layouts.md` for the full-document results.
  """

  use ExUnit.Case, async: true

  alias BrusselsWtf.Processors.UccleCouncil

  @fixtures "test/support/fixtures/uccle/agendas"
  @base File.read!("#{@fixtures}/2026-10-15-odj.excerpt.txt")
  @complementary File.read!("#{@fixtures}/2026-10-15-odjc.excerpt.txt")
  @malformed File.read!("#{@fixtures}/2026-06-25-odj.excerpt.txt")

  defp input(text, overrides \\ %{}) do
    Map.merge(
      %{
        "commune_slug" => "uccle",
        "meeting_identifier" => "2026-10-15",
        "scheduled_on" => "2026-10-15",
        "role" => "agenda",
        "language" => "bilingual",
        "text" => text
      },
      overrides
    )
  end

  defp base, do: UccleCouncil.normalize(input(@base, %{"page_count" => 3}))

  defp complementary do
    UccleCouncil.normalize(
      input(@complementary, %{"role" => "complementary_agenda", "page_count" => 2})
    )
  end

  describe "the agenda layout" do
    test "every emitted excerpt occurs on its cited page" do
      assert {:ok, normalized_base} = base()
      assert {:ok, normalized_complementary} = complementary()

      BrusselsWtf.UccleAgendaEvidence.assert_on_cited_pages(normalized_base, @base)

      BrusselsWtf.UccleAgendaEvidence.assert_on_cited_pages(
        normalized_complementary,
        @complementary
      )
    end

    test "the base agenda yields its numbered points, proposals only" do
      assert {:ok, normalized} = base()

      assert normalized["meeting_identifier"] == "2026-10-15"
      assert normalized["scheduled_on"] == "2026-10-15"
      assert normalized["agenda"] == %{"kind" => "base", "language" => "bilingual"}
      assert normalized["restates_agenda"] == true

      assert Enum.map(normalized["items"], & &1["item_number"]) ==
               Enum.map(2..7, &Integer.to_string/1)

      refute Enum.any?(normalized["items"], &Map.has_key?(&1, "decisions"))
    end

    test "the complementary agenda is read as its own full, renumbered agenda" do
      assert {:ok, normalized} = complementary()

      assert normalized["agenda"] == %{"kind" => "complementary", "language" => "bilingual"}

      assert Enum.map(normalized["items"], & &1["item_number"]) ==
               Enum.map(2..9, &Integer.to_string/1)

      [evidence] =
        for item <- normalized["items"],
            item["item_number"] == "6",
            proposal <- item["proposals"],
            do: proposal["evidence"]

      assert evidence["location"] == "Ordre du jour complémentaire, point 6, page 2/2"
      assert evidence["applicable_from"] == "2026-10-15"
    end

    test "the same official wording keeps one identity although its number shifts" do
      {:ok, base} = base()
      {:ok, complementary} = complementary()

      cemetery = fn normalized ->
        Enum.find(
          normalized["items"],
          &String.starts_with?(&1["source_wording"], "Cimetière du Dieweg")
        )
      end

      assert cemetery.(base)["item_number"] == "5"
      assert cemetery.(complementary)["item_number"] == "6"

      assert cemetery.(base)["authoritative_identifier"] ==
               cemetery.(complementary)["authoritative_identifier"]

      # Number 5 of the complementary agenda is a different matter and must not merge.
      other = Enum.find(complementary["items"], &(&1["item_number"] == "5"))
      refute other["authoritative_identifier"] == cemetery.(base)["authoritative_identifier"]

      identities = fn normalized ->
        MapSet.new(normalized["items"], & &1["authoritative_identifier"])
      end

      assert MapSet.subset?(identities.(base), identities.(complementary))
      assert MapSet.size(identities.(complementary)) == 8
    end

    test "the identity is scoped to the meeting, so a repeated wording cannot link meetings" do
      {:ok, normalized} = base()

      assert Enum.all?(
               normalized["items"],
               &String.starts_with?(&1["authoritative_identifier"], "uccle-2026-10-15-")
             )
    end

    test "only French wording is emitted, across a page break too" do
      {:ok, normalized} = base()
      by_number = Map.new(normalized["items"], &{&1["item_number"], &1})

      # French on page 1, Dutch on page 2.
      assert by_number["4"]["source_wording"] ==
               "Réfection des trottoirs - Exercice 2026.- Approbation de la dépense, " <>
                 "des documents du marché, de la procédure de passation du marché."

      # French continues on the next page before its Dutch translation.
      split = by_number["6"]
      assert split["source_wording"] =~ "intergénérationnels le 13 novembre 2026."
      refute split["source_wording"] =~ "Dienst Senioren"
      [proposal] = split["proposals"]
      assert proposal["evidence"]["location"] == "Ordre du jour, point 6, pages 2-3/3"

      refute Enum.any?(normalized["items"], &(&1["source_wording"] =~ "Goedkeuring"))
      refute Enum.any?(normalized["items"], &(&1["source_wording"] =~ "DEPARTEMENT"))
    end

    test "non-votable points stay on the record without a proposal" do
      {:ok, normalized} = complementary()
      by_number = Map.new(normalized["items"], &{&1["item_number"], &1})

      for number <- ~w(2 9) do
        refute Map.has_key?(by_number[number], "proposals"), "point #{number} is not votable"
        assert by_number[number]["source_wording"] != ""
      end

      for number <- ~w(3 4 5 6 7 8) do
        assert [%{"text" => text}] = by_number[number]["proposals"]
        assert text == by_number[number]["source_wording"]
      end
    end

    test "normalization is deterministic" do
      assert base() == base()
    end
  end

  describe "fail-closed ambiguity" do
    test "the publisher's real malformed point opens a review case" do
      assert {:error, {:normalization_ambiguity, details}} =
               UccleCouncil.normalize(
                 input(@malformed, %{
                   "meeting_identifier" => "2026-06-25",
                   "scheduled_on" => "2026-06-25",
                   "page_count" => 2
                 })
               )

      assert details["contract"] == "uccle-council"
      assert Enum.any?(details["unverified"], &(&1["reason"] == "agenda_line_outside_item"))
      assert Enum.any?(details["unverified"], &(&1["reason"] == "agenda_item_number_gap"))
    end

    test "a date that the document does not state opens a review case" do
      assert {:error, {:normalization_ambiguity, details}} =
               UccleCouncil.normalize(
                 input(@base, %{
                   "meeting_identifier" => "2026-10-22",
                   "scheduled_on" => "2026-10-22"
                 })
               )

      assert "meeting_heading_fr" in details["missing_markers"]
      assert "meeting_heading_nl" in details["missing_markers"]
    end

    test "another commune's document opens a review case" do
      text = String.replace(@base, "COMMUNE D'UCCLE", "COMMUNE DE FOREST")

      assert {:error, {:normalization_ambiguity, %{"missing_markers" => ["commune_fr"]}}} =
               UccleCouncil.normalize(input(text))
    end

    test "a role that contradicts the heading opens a review case" do
      assert {:error, {:normalization_ambiguity, %{"missing_markers" => ["agenda_heading"]}}} =
               UccleCouncil.normalize(input(@complementary))

      assert {:error, {:normalization_ambiguity, %{"missing_markers" => ["agenda_heading"]}}} =
               UccleCouncil.normalize(input(@base, %{"role" => "complementary_agenda"}))
    end

    test "a closed-session section opens a review case" do
      text =
        String.replace(
          @base,
          "SÉANCE PUBLIQUE - OPENBARE ZITTING",
          "SÉANCE PUBLIQUE - OPENBARE ZITTING\n    SÉANCE À HUIS CLOS - BESLOTEN ZITTING"
        )

      assert {:error, {:normalization_ambiguity, %{"unexpected_markers" => ["closed_session"]}}} =
               UccleCouncil.normalize(input(text))
    end

    test "a page count that disagrees with the document opens a review case" do
      assert {:error, {:normalization_ambiguity, details}} =
               UccleCouncil.normalize(input(@base, %{"page_count" => 4}))

      assert Enum.any?(details["unverified"], &(&1["reason"] == "agenda_page_count_mismatch"))
    end

    test "a missing page footer opens a review case" do
      text = String.replace(@base, ~r/\n[^\n]*Openbare agenda +2\/3/u, "")

      assert {:error, {:normalization_ambiguity, details}} = UccleCouncil.normalize(input(text))
      assert Enum.any?(details["unverified"], &(&1["reason"] == "agenda_page_footer_mismatch"))
    end

    test "a skipped point number opens a review case" do
      text = String.replace(@base, ~r/^    5( +)Cimetière/mu, "    6\\1Cimetière")

      assert {:error, {:normalization_ambiguity, details}} = UccleCouncil.normalize(input(text))
      assert Enum.any?(details["unverified"], &(&1["reason"] == "agenda_item_number_gap"))
    end

    test "a point without a Dutch translation opens a review case" do
      text =
        String.replace(
          @base,
          "             Goedkeuring van het register van de zitting van de Gemeenteraad van 10 september 2026.\n",
          ""
        )

      assert {:error, {:normalization_ambiguity, details}} = UccleCouncil.normalize(input(text))

      assert %{"item_number" => "3", "reason" => "agenda_item_paragraphs_unreadable"} in details[
               "unverified"
             ]
    end

    test "Dutch in the French position opens a review case rather than publishing it" do
      text =
        @base
        |> String.replace(
          "Approbation du registre de la séance du Conseil communal du 10 septembre 2026.",
          "@@"
        )
        |> String.replace(
          "Goedkeuring van het register van de zitting van de Gemeenteraad van 10 september 2026.",
          "Approbation du registre de la séance du Conseil communal du 10 septembre 2026."
        )
        |> String.replace(
          "@@",
          "Goedkeuring van het register van de zitting van de Gemeenteraad van 10 september 2026."
        )

      assert {:error, {:normalization_ambiguity, details}} = UccleCouncil.normalize(input(text))

      assert Enum.any?(
               details["unverified"],
               &(&1["item_number"] == "3" and &1["reason"] == "agenda_item_french_not_dominant")
             )
    end

    test "two points with the same official wording open a review case" do
      text =
        String.replace(
          @base,
          "Cimetière du Dieweg – concession à perpétuité pleine terre (CPPT) n°2198 - demande de\n             prolongation tardive – dérogation",
          "Approbation du registre de la séance du Conseil communal du 10 septembre 2026."
        )

      assert {:error, {:normalization_ambiguity, details}} = UccleCouncil.normalize(input(text))
      assert Enum.any?(details["unverified"], &(&1["reason"] == "agenda_item_wording_duplicated"))
    end
  end

  describe "documents this contract does not cover" do
    test "other communes, roles and malformed context stay unavailable" do
      for overrides <- [
            %{"commune_slug" => "ixelles"},
            %{"role" => "explanatory_note"},
            %{"role" => "interpellation"},
            %{"role" => nil},
            %{"scheduled_on" => "not-a-date"},
            %{"meeting_identifier" => "270"},
            %{"text" => "   "}
          ] do
        assert UccleCouncil.normalize(input(@base, overrides)) ==
                 {:error, :processor_unimplemented}
      end

      assert UccleCouncil.normalize(:not_a_map) == {:error, :processor_unimplemented}
    end

    test "a recorded corpus meeting stays unavailable, so its sealed page cannot change" do
      text =
        @base
        |> String.replace("DU 15 OCTOBRE 2026", "DU 10 SEPTEMBRE 2026")
        |> String.replace("VAN 15 OKTOBER 2026", "VAN 10 SEPTEMBER 2026")
        |> String.replace("15.10.2026", "10.09.2026")

      assert UccleCouncil.normalize(
               input(text, %{"meeting_identifier" => "2026-09-10", "scheduled_on" => "2026-09-10"})
             ) == {:error, :processor_unimplemented}
    end
  end
end
