defmodule BrusselsWtf.Council.VoteTally do
  @moduledoc """
  Reads the council's own vote line and classifies a recorded tally.

  Municipal minutes state a vote as a total of voters followed by the categories
  that received votes, for example `38 votants : 38 votes positifs.` or
  `34 votants : 23 votes positifs, 1 vote négatif, 10 abstentions.` A category the
  line omits is recorded as zero only when the stated categories add up to the
  stated number of voters; any other line is not a tally this module can read.
  """

  @type counts :: %{
          voters: non_neg_integer(),
          for: non_neg_integer(),
          against: non_neg_integer(),
          abstentions: non_neg_integer()
        }

  @line ~r/(\d+)\s+(?:votants|stemmers)\s*:\s*([^.]*)/iu

  @categories [
    {:for, ~r/^(\d+)\s+(?:votes?\s+positifs?|positieve\s+stemm?en|ja-?stemm?en)$/iu},
    {:against, ~r/^(\d+)\s+(?:votes?\s+n[ée]gatifs?|negatieve\s+stemm?en|neen-?stemm?en)$/iu},
    {:abstentions, ~r/^(\d+)\s+(?:abstentions?|onthoudingen|onthouding)$/iu}
  ]

  @doc "Parses the first complete vote line in `text`."
  @spec parse(String.t() | nil) :: {:ok, counts()} | :error
  def parse(text) when is_binary(text) do
    text = String.replace(text, ~r/\s+/u, " ")

    case Regex.run(@line, text) do
      [_, voters, parts] -> parse_parts(String.to_integer(voters), parts)
      _ -> :error
    end
  end

  def parse(_text), do: :error

  defp parse_parts(voters, parts) do
    parsed =
      parts
      |> String.split(~r/\s*(?:,|;|\bet\b|\ben\b)\s*/u, trim: true)
      |> Enum.map(&category/1)

    with false <- Enum.any?(parsed, &(&1 == :error)),
         categories = Enum.map(parsed, &elem(&1, 0)),
         true <- categories == Enum.uniq(categories),
         counts = Map.merge(%{for: 0, against: 0, abstentions: 0}, Map.new(parsed)),
         true <- counts.for + counts.against + counts.abstentions == voters do
      {:ok, Map.put(counts, :voters, voters)}
    else
      _ -> :error
    end
  end

  defp category(part) do
    part = String.trim(part)

    Enum.find_value(@categories, :error, fn {key, pattern} ->
      case Regex.run(pattern, part) do
        [_, value] -> {key, String.to_integer(value)}
        _ -> nil
      end
    end)
  end

  @doc """
  Completes a normalized `vote` candidate from its own evidence excerpt.

  Counts the normalizer stated are kept. Omitted categories become zero only when
  the cited vote line reads as a complete tally that agrees with every stated count.
  Otherwise the candidate is returned unchanged.
  """
  @spec complete(map() | nil) :: map() | nil
  def complete(%{} = vote) do
    with {:ok, parsed} <- parse(get_in(vote, ["evidence", "excerpt"])),
         true <- agrees?(vote, parsed) do
      vote
      |> Map.put("for", parsed.for)
      |> Map.put("against", parsed.against)
      |> Map.put("abstentions", parsed.abstentions)
    else
      _ -> vote
    end
  end

  def complete(vote), do: vote

  defp agrees?(vote, parsed) do
    Enum.all?([{"for", :for}, {"against", :against}, {"abstentions", :abstentions}], fn
      {key, field} -> is_nil(vote[key]) or vote[key] == Map.fetch!(parsed, field)
    end)
  end

  @doc """
  Classifies a decision's recorded tally.

  `:contested` means at least one vote against or abstention. `:unanimous` means
  every recorded vote was in favour. `:not_recorded` means the tally is absent or
  incomplete, so no claim about unanimity is made.
  """
  @spec classify(map() | nil) :: :unanimous | :contested | :not_recorded
  def classify(%{votes_for: for_votes, votes_against: against, abstentions: abstentions})
      when is_integer(for_votes) and is_integer(against) and is_integer(abstentions) do
    cond do
      against > 0 or abstentions > 0 -> :contested
      for_votes > 0 -> :unanimous
      true -> :not_recorded
    end
  end

  def classify(%{votes_against: against}) when is_integer(against) and against > 0,
    do: :contested

  def classify(%{abstentions: abstentions}) when is_integer(abstentions) and abstentions > 0,
    do: :contested

  def classify(_decision), do: :not_recorded
end
