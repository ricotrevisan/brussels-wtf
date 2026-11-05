defmodule BrusselsWtf.Council.HeadlineTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Council.Headline

  @source "Octroi d'un subside de 20.000,00 EUR et de 680,00 EUR en nature pour Pride@Ixelles le 15 mai 2026."

  test "keeps a headline whose figures come from the source, in any number format" do
    assert Headline.accept(" €20,000 for Pride@Ixelles ", @source, false) ==
             "€20,000 for Pride@Ixelles"

    assert Headline.accept("20 000 € pour Pride@Ixelles", @source, false)
    assert Headline.accept("€ 20.000 voor Pride@Ixelles", @source, false)
    assert Headline.accept("€680 in kind for Pride@Ixelles", @source, false)
  end

  test "drops a headline with a figure the source does not contain" do
    refute Headline.accept("€25,000 for Pride@Ixelles", @source, false)
    refute Headline.accept("2,000 people at Pride@Ixelles", @source, false)
  end

  test "never lets a proposal read as a decision, in any language" do
    for headline <- [
          "Subsidy approved for Pride",
          "Subside approuvé pour Pride",
          "Subsidie goedgekeurd",
          "Council voted a subsidy"
        ] do
      refute Headline.accept(headline, @source, false)
    end

    for headline <- [
          "Approval of a settlement with a company",
          "Approbation du procès-verbal",
          "Goedkeuring van de notulen"
        ] do
      refute Headline.accept(headline, @source, false)
      assert Headline.accept(headline, @source, true)
    end

    assert Headline.accept("Settlement with a company", @source, false)
    assert Headline.accept("Subsidy approved for Pride", @source, true)
  end

  test "spots a translation that is really the French headline" do
    french = "Rectification de la date de la décision sur le réaménagement de l'avenue"
    assert Headline.untranslated?(french, french)

    assert Headline.untranslated?(
             "Rectification de la date de la décision sur le réaménagement de l'avenue.",
             french
           )

    refute Headline.untranslated?(
             "Correcting the date of the decision on the avenue works",
             french
           )

    refute Headline.untranslated?(nil, french)
  end

  test "an undecided item cannot read as already done" do
    for headline <- [
          "Soil study framework contract: Ixelles joins",
          "Appointment of Mr. Diego NARANJO to asbl X",
          "Acknowledgement of a resignation",
          "Désignation d'un représentant",
          "Benoeming van een vertegenwoordiger",
          "Sidewalk renovation: conditions approval",
          "Installation of Ms. Vinciane Pirottin as councilor",
          "Granting of eco-cheques to nursery staff",
          "Ratification of a protocol"
        ] do
      refute Headline.accept(headline, @source, false), headline
      assert Headline.accept(headline, @source, true), headline
    end

    assert Headline.accept("Representative to asbl X: Mr Y proposed", @source, false)
    assert Headline.accept("Soil study framework contract", @source, false)
  end

  test "drops blank, missing and overlong headlines" do
    refute Headline.accept("   ", @source, false)
    refute Headline.accept(nil, @source, false)
    refute Headline.accept(String.duplicate("a", 101), @source, false)
  end
end
