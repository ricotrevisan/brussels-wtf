defmodule BrusselsWtf.Council.VoteTallyTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Council.VoteTally

  describe "parse/1" do
    test "a unanimous French line records zero against and zero abstentions" do
      assert {:ok, %{voters: 38, for: 38, against: 0, abstentions: 0}} =
               VoteTally.parse("Le Conseil approuve. 38 votants : 38 votes positifs.")
    end

    test "the Dutch twin line reads the same" do
      assert {:ok, %{voters: 37, for: 37, against: 0, abstentions: 0}} =
               VoteTally.parse("De Raad keurt goed.\n37 stemmers : 37 positieve stemmen.")
    end

    test "a split vote from the Forest 22 April 2025 minutes" do
      assert {:ok, %{voters: 34, for: 23, against: 1, abstentions: 10}} =
               VoteTally.parse("34 votants : 23 votes positifs, 1 vote négatif, 10 abstentions.")
    end

    test "categories that do not add up to the voters are not a tally" do
      assert :error = VoteTally.parse("38 votants : 36 votes positifs.")
    end

    test "unrecognised categories and absent lines are not a tally" do
      assert :error = VoteTally.parse("38 votants : 38 votes blancs.")
      assert :error = VoteTally.parse("Le Conseil approuve.")
      assert :error = VoteTally.parse(nil)
    end

    test "a repeated category is not a tally" do
      assert :error = VoteTally.parse("4 votants : 2 votes positifs, 2 votes positifs.")
    end
  end

  describe "complete/1" do
    test "fills omitted categories as zero from a complete cited line" do
      vote = %{"for" => 38, "evidence" => %{"excerpt" => "38 votants : 38 votes positifs."}}

      assert %{"for" => 38, "against" => 0, "abstentions" => 0} = VoteTally.complete(vote)
    end

    test "leaves a vote unchanged when the cited line disagrees with a stated count" do
      vote = %{"for" => 37, "evidence" => %{"excerpt" => "38 votants : 38 votes positifs."}}

      assert VoteTally.complete(vote) == vote
    end

    test "leaves a vote unchanged when the excerpt carries no tally" do
      vote = %{"for" => 37, "evidence" => %{"excerpt" => "Le Conseil approuve."}}

      assert VoteTally.complete(vote) == vote
      assert VoteTally.complete(nil) == nil
    end
  end

  describe "classify/1" do
    test "unanimous, contested, and not recorded" do
      assert :unanimous = VoteTally.classify(%{votes_for: 38, votes_against: 0, abstentions: 0})
      assert :contested = VoteTally.classify(%{votes_for: 23, votes_against: 1, abstentions: 10})
      assert :contested = VoteTally.classify(%{votes_for: 30, votes_against: 0, abstentions: 2})

      assert :contested =
               VoteTally.classify(%{votes_for: nil, votes_against: 3, abstentions: nil})

      assert :not_recorded =
               VoteTally.classify(%{votes_for: 37, votes_against: nil, abstentions: nil})

      assert :not_recorded =
               VoteTally.classify(%{votes_for: nil, votes_against: nil, abstentions: nil})

      assert :not_recorded = VoteTally.classify(nil)
    end
  end
end
