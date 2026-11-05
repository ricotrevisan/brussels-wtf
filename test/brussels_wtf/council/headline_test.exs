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

    assert Headline.accept("Goedkeuring van de notulen", @source, false)
    assert Headline.accept("Approbation du procès-verbal", @source, false)
    assert Headline.accept("Subsidy approved for Pride", @source, true)
  end

  test "drops blank, missing and overlong headlines" do
    refute Headline.accept("   ", @source, false)
    refute Headline.accept(nil, @source, false)
    refute Headline.accept(String.duplicate("a", 101), @source, false)
  end
end
