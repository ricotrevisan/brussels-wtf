defmodule BrusselsWtfWeb.PublicShellTest do
  use ExUnit.Case, async: true

  alias BrusselsWtfWeb.{PublicDate, PublicShell}

  describe "split_title/1" do
    test "keeps every word of the official title across its two parts" do
      title =
        "Collapse of the party wall located at Rue du Brochet 30-32, 1050 Ixelles. Approval of the settlement agreement."

      {lead, rest} = PublicShell.split_title(title)

      assert lead == "Collapse of the party wall located at Rue du Brochet 30-32, 1050 Ixelles."
      assert rest == "Approval of the settlement agreement."
      assert lead <> " " <> rest == title
    end

    test "does not split on a person's title or an abbreviation" do
      title = "Verification of credentials of the councillor Ms. Vinciane PIROTTIN"
      assert PublicShell.split_title(title) == {title, nil}

      numbered = "Works framework agreement concerning contract no. 2026-108"
      assert PublicShell.split_title(numbered) == {numbered, nil}
    end

    test "leaves a short first sentence attached" do
      title = "Motion. Accelerate the ecological transition"
      assert PublicShell.split_title(title) == {title, nil}
    end
  end

  describe "amount_in/1" do
    test "writes the first amount one way per language" do
      assert PublicShell.amount_in("Subsidy amounting to EUR 20,000.00 and more", "en") ==
               "€20,000"

      assert PublicShell.amount_in("Settlement for 43,300.56 EUR incl. VAT", "en") == "€43,300.56"
      assert PublicShell.amount_in("Subvention de 20 000 € pour un festival", "fr") == "20 000 €"
      assert PublicShell.amount_in("Transaction de 43.300,56 EUR TVAC", "fr") == "43 300,56 €"
      assert PublicShell.amount_in("Dading voor 1.250 EUR", "nl") == "€ 1.250"
    end

    test "ignores titles without money" do
      assert PublicShell.amount_in("Works agreement no. 2026-108", "en") == nil
      assert PublicShell.amount_in(nil, "en") == nil
    end
  end

  describe "topic_of/1" do
    test "labels by fixed keywords and falls back to a general label" do
      assert PublicShell.topic_of("Subvention pour un festival") == :topic_subsidy
      assert PublicShell.topic_of("Settlement agreement with SCOLARES") == :topic_settlement
      assert PublicShell.topic_of("Designation of a representative") == :topic_general
      assert PublicShell.topic_of(nil) == :topic_general
    end
  end

  describe "vote_text/4" do
    test "uses one wording per language and handles singulars" do
      assert PublicShell.vote_text("en", 24, 9, 4) == "24 for, 9 against, 4 abstained"
      assert PublicShell.vote_text("fr", 24, 9, 1) == "24 pour, 9 contre, 1 abstention"
      assert PublicShell.vote_text("fr", 24, 9, 4) == "24 pour, 9 contre, 4 abstentions"
      assert PublicShell.vote_text("nl", 24, 9, 1) == "24 voor, 9 tegen, 1 onthouding"
      assert PublicShell.vote_text("nl", 24, 9, 4) == "24 voor, 9 tegen, 4 onthoudingen"
    end

    test "says nothing when no tally is recorded" do
      assert PublicShell.vote_text("en", nil, nil, nil) == nil
    end
  end

  test "dates read in the page language" do
    assert PublicDate.long(~D[2026-10-15], "en") == "15 October 2026"
    assert PublicDate.long(~D[2026-10-15], "fr") == "15 octobre 2026"
    assert PublicDate.long(~D[2026-03-01], "nl") == "1 maart 2026"
  end
end
