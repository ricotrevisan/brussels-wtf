defmodule BrusselsWtf.Processors.CityOfBrusselsCouncilTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Processors.CityOfBrusselsCouncil, as: Normalizer

  @fixtures "test/support/fixtures/city_of_brussels"
  @french_lines ~r/^\s*(Dossiers de|Questions|Motions|Communications)/

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))
  defp agenda_text, do: fixture("agenda_20261012_excerpt.txt")

  defp input(text, overrides \\ %{}) do
    Map.merge(
      %{
        "commune_slug" => "city-of-brussels",
        "meeting_identifier" => "2026-10-12",
        "scheduled_on" => "2026-10-12",
        "role" => "agenda",
        "language" => "fr",
        "text" => text,
        "page_count" => text |> String.split("\f", trim: true) |> length()
      },
      overrides
    )
  end

  defp ambiguity!(input) do
    assert {:error, {:normalization_ambiguity, details}} = Normalizer.normalize(input)
    assert details["contract"] == "city-of-brussels-council"
    details
  end

  defp item(normalized, number),
    do: Enum.find(normalized["items"], &(&1["item_number"] == number))

  describe "real agenda pages" do
    test "reads every numbered point with its dossier identifier and source wording" do
      assert {:ok, normalized} = Normalizer.normalize(input(agenda_text()))

      assert normalized["meeting_identifier"] == "2026-10-12"
      assert normalized["scheduled_on"] == "2026-10-12"
      assert normalized["agenda"] == %{"kind" => "base", "language" => "fr"}

      assert Enum.map(normalized["items"], & &1["item_number"]) == ~w(3 5 6 13)

      assert item(normalized, "5")["authoritative_identifier"] == "2732923"

      assert item(normalized, "5")["source_wording"] ==
               "Convention entre la Croix Rouge de Belgique et la Ville de Bruxelles. " <>
                 "Adopter la convention entre la Croix Rouge de Belgique et la Ville de Bruxelles."
    end

    test "every emitted excerpt occurs on the page its location cites" do
      for {name, overrides} <- [
            {"agenda_20261012_excerpt.txt", %{}},
            {"supplement_20261012_excerpt.txt", %{"role" => "supplement"}},
            {"addendum_20260420.txt",
             %{
               "role" => "addendum",
               "meeting_identifier" => "2026-04-20",
               "scheduled_on" => "2026-04-20"
             }}
          ] do
        text = fixture(name)
        assert {:ok, normalized} = Normalizer.normalize(input(text, overrides))
        pages = String.split(text, "\f", trim: true)
        proposals = Enum.flat_map(normalized["items"], &List.wrap(&1["proposals"]))
        assert proposals != []

        for proposal <- proposals do
          evidence = proposal["evidence"]
          assert evidence["claim"] == "proposal"
          [_, page] = Regex.run(~r/, page (\d+)\/\d+$/, evidence["location"])

          assert :ok =
                   Normalizer.verify_excerpt(
                     evidence["excerpt"],
                     Enum.at(pages, String.to_integer(page) - 1)
                   )
        end
      end
    end

    test "the wording leaves out the department line, separators, footers and headings" do
      assert {:ok, normalized} = Normalizer.normalize(input(agenda_text()))

      for candidate <- normalized["items"] do
        wording = candidate["source_wording"]
        refute wording =~ "(R)"
        refute wording =~ "-----"
        refute wording =~ "Ordre du jour séance publique"
        refute wording =~ @french_lines
      end
    end

    test "a header wrapped over two lines still yields its dossier identifier" do
      text =
        String.replace(
          agenda_text(),
          "[5]   Secrétaire - - Planification d'urgence - 2732923 (R)",
          "[5]   Secrétaire - - Planification d'urgence -\n      2732923 (R)"
        )

      assert {:ok, normalized} = Normalizer.normalize(input(text))
      assert item(normalized, "5")["authoritative_identifier"] == "2732923"
      refute item(normalized, "5")["source_wording"] =~ "2732923"
    end

    test "the supplement and addendum are their own agenda versions" do
      assert {:ok, %{"agenda" => %{"kind" => "supplement"}, "items" => [first | _]}} =
               Normalizer.normalize(
                 input(fixture("supplement_20261012_excerpt.txt"), %{"role" => "supplement"})
               )

      assert first["item_number"] == "74"
      assert first["authoritative_identifier"] == "2737563"

      assert first["proposals"] |> hd() |> get_in(["evidence", "location"]) =~
               "Supplément à l'ordre du jour, point 74, page 1/2"

      assert {:ok, %{"agenda" => %{"kind" => "addendum"}, "items" => [motion]}} =
               Normalizer.normalize(
                 input(fixture("addendum_20260420.txt"), %{
                   "role" => "addendum",
                   "meeting_identifier" => "2026-04-20",
                   "scheduled_on" => "2026-04-20"
                 })
               )

      assert motion["item_number"] == "185"
      assert [_] = motion["proposals"]
    end
  end

  describe "ADR 0005 votable points" do
    test "a council interpellation is kept as an item without a proposal" do
      assert {:ok, normalized} = Normalizer.normalize(input(agenda_text()))
      interpellation = item(normalized, "3")

      assert interpellation["source_wording"] =~
               "Interpellation concernant l'avenir du Palais du Midi"

      refute Map.has_key?(interpellation, "proposals")
    end

    test "a point the council only takes note of carries no proposal" do
      assert {:ok, normalized} = Normalizer.normalize(input(agenda_text()))

      information = item(normalized, "13")
      assert information["source_wording"] =~ "Prendre pour information"
      refute Map.has_key?(information, "proposals")
    end

    test "a point that adopts something alongside its note stays a proposal" do
      text =
        String.replace(
          agenda_text(),
          "Adopter la convention entre la Croix Rouge de Belgique et la Ville de Bruxelles.",
          "1) Adopter la convention.- 2) Prendre pour information le rapport."
        )

      assert {:ok, normalized} = Normalizer.normalize(input(text))
      assert [_] = item(normalized, "5")["proposals"]
    end

    test "numbered points that only take note carry no proposal" do
      text =
        String.replace(
          agenda_text(),
          "Adopter la convention entre la Croix Rouge de Belgique et la Ville de Bruxelles.",
          "1) Prendre connaissance de la convention.- 2) Prendre acte du rapport."
        )

      assert {:ok, normalized} = Normalizer.normalize(input(text))
      refute Map.has_key?(item(normalized, "5"), "proposals")
    end

    test "a number inside note wording is not a further action" do
      text =
        String.replace(
          agenda_text(),
          "Adopter la convention entre la Croix Rouge de Belgique et la Ville de Bruxelles.",
          "Prendre acte de l'article 42, § 1er, d) 2) de la loi."
        )

      assert {:ok, normalized} = Normalizer.normalize(input(text))
      refute Map.has_key?(item(normalized, "5"), "proposals")
    end

    test "motions are proposals and questions are not" do
      assert {:ok, normalized} =
               Normalizer.normalize(
                 input(fixture("supplement_20261012_excerpt.txt"), %{"role" => "supplement"})
               )

      assert [_] = item(normalized, "108")["proposals"]
      refute Map.has_key?(item(normalized, "109"), "proposals")
    end

    test "no agenda ever emits a decision or an outcome" do
      assert {:ok, normalized} = Normalizer.normalize(input(agenda_text()))

      for candidate <- normalized["items"] do
        refute Map.has_key?(candidate, "decisions")
        refute Map.has_key?(candidate, "outcome")
      end
    end
  end

  describe "documents outside the contract return unimplemented" do
    test "supporting documents and other roles never create items" do
      for role <- ~w(supporting_document minutes item_listing document_listing index) do
        assert {:error, :processor_unimplemented} =
                 Normalizer.normalize(input(agenda_text(), %{"role" => role}))
      end
    end

    test "a recorded corpus meeting stays unavailable, so its sealed page cannot change" do
      for date <- ~w(2026-06-08 2026-06-29 2026-09-07) do
        assert {:error, :processor_unimplemented} =
                 Normalizer.normalize(
                   input(agenda_text(), %{"meeting_identifier" => date, "scheduled_on" => date})
                 )
      end
    end

    test "missing context is refused rather than guessed" do
      for overrides <- [
            %{"commune_slug" => "ixelles"},
            %{"role" => nil},
            %{"meeting_identifier" => nil},
            %{"meeting_identifier" => "   "},
            %{"scheduled_on" => nil},
            %{"scheduled_on" => "12/10/2026"},
            %{"text" => nil},
            %{"text" => "  "}
          ] do
        assert {:error, :processor_unimplemented} =
                 Normalizer.normalize(input(agenda_text(), overrides))
      end

      assert {:error, :processor_unimplemented} = Normalizer.normalize(:not_a_map)
    end
  end

  describe "ambiguity opens a review case instead of guessing" do
    test "a date other than the discovered meeting" do
      details =
        ambiguity!(
          input(agenda_text(), %{
            "meeting_identifier" => "2026-10-13",
            "scheduled_on" => "2026-10-13"
          })
        )

      assert "meeting_heading" in details["missing_markers"]
    end

    test "a meeting identifier that disagrees with the date" do
      details = ambiguity!(input(agenda_text(), %{"meeting_identifier" => "2026-09-21"}))
      assert "meeting_identifier" in details["missing_markers"]
    end

    test "another commune's or a Dutch heading" do
      details =
        ambiguity!(
          input(String.replace(agenda_text(), "VILLE DE BRUXELLES", "COMMUNE D'IXELLES"))
        )

      assert "commune" in details["missing_markers"]

      details =
        ambiguity!(input(String.replace(agenda_text(), "Séance du lundi", "Zitting van maandag")))

      assert "meeting_heading" in details["missing_markers"]
    end

    test "a heading that disagrees with the discovered role" do
      details = ambiguity!(input(agenda_text(), %{"role" => "supplement"}))
      assert "document_title" in details["missing_markers"]
    end

    test "a closed session document" do
      text =
        String.replace(agenda_text(), "Séance publique\n", "Séance à huis clos\n", global: false)

      details = ambiguity!(input(text))
      assert "public_session" in details["missing_markers"]
    end

    test "a page without its dated, numbered footer" do
      text =
        String.replace(
          agenda_text(),
          "lundi 12 octobre 2026                    1",
          "                    1"
        )

      details = ambiguity!(input(text))
      assert %{"reason" => "page_footer_unreadable", "page" => 1} in details["unverified"]
    end

    test "a page count that disagrees with the extraction" do
      details = ambiguity!(input(agenda_text(), %{"page_count" => 9}))
      assert "page_count" in details["missing_markers"]
    end

    test "an unknown heading between points" do
      text =
        String.replace(
          agenda_text(),
          "Dossiers de Mme l'Echevine Frelinx",
          "Election d'un neuvième Echevin"
        )

      details = ambiguity!(input(text))
      assert %{"reason" => "agenda_heading_unknown", "page" => 2} in details["unverified"]
    end

    test "a point whose separator disappeared" do
      text =
        String.replace(
          agenda_text(),
          ~r/-{20,}\s*\n(\s*\[6\])/u,
          "\\g{1}"
        )

      details = ambiguity!(input(text))
      assert Enum.any?(details["unverified"], &(&1["reason"] == "agenda_item_not_terminated"))
    end

    test "a point without a readable dossier identifier" do
      text = String.replace(agenda_text(), "2732923 (R)", "(R)")
      details = ambiguity!(input(text))
      assert Enum.any?(details["unverified"], &(&1["reason"] == "agenda_item_header_unreadable"))
    end

    test "a point with no wording" do
      text =
        String.replace(
          agenda_text(),
          ~r/(2732923 \(R\)\n).*?\n(\s*-{20,})/su,
          "\\g{1}\\g{2}"
        )

      details = ambiguity!(input(text))
      assert Enum.any?(details["unverified"], &(&1["reason"] == "agenda_item_wording_empty"))
    end

    test "repeated point numbers and repeated dossiers" do
      details = ambiguity!(input(String.replace(agenda_text(), "[6] ", "[5] ")))

      assert Enum.any?(
               details["unverified"],
               &(&1["reason"] == "agenda_item_number_not_increasing")
             )

      details = ambiguity!(input(String.replace(agenda_text(), "2736004", "2732923")))
      assert Enum.any?(details["unverified"], &(&1["reason"] == "agenda_item_dossier_repeated"))
    end

    test "a point that crosses a page break cannot cite one page" do
      text =
        agenda_text()
        |> String.replace(~r/-{20,}\s*\n+(\s*Ordre du jour séance publique)/u, "\\g{1}",
          global: false
        )
        |> String.replace(
          "      Dossiers de Mme l'Echevine Frelinx",
          "suite du texte.\n#{String.duplicate("-", 40)}\n      Dossiers de Mme l'Echevine Frelinx"
        )

      details = ambiguity!(input(text))
      assert Enum.any?(details["unverified"], &(&1["reason"] == "agenda_item_spans_pages"))
    end

    test "a document with no numbered points" do
      text = String.replace(agenda_text(), ~r/\[\d+\]/u, "")
      ambiguity!(input(text))
    end

    test "the details hold only reasons, never document wording" do
      text =
        String.replace(
          agenda_text(),
          "Dossiers de Mme l'Echevine Frelinx",
          "Election confidentielle"
        )

      refute inspect(ambiguity!(input(text))) =~ "confidentielle"
    end
  end
end
