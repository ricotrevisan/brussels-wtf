defmodule BrusselsWtf.Ops.CBEIndexBenchmark do
  @moduledoc """
  Read-only, content-free acceptance benchmark; invoke with Repo running.
  First-use means a new caller, not flushed PostgreSQL/OS caches. Never flush
  shared production caches. CSV comparison is explicit and scans each source.
  """
  alias BrusselsWtf.CBE.{Index, Source}

  def run(sha256, numbers, options \\ []) do
    repeats = Keyword.get(options, :repeats, 10)
    directory = Keyword.get(options, :compare_directory)

    unless is_list(numbers) and length(numbers) in 1..10 and
             is_integer(repeats) and repeats in 1..100,
           do: raise(ArgumentError, "invalid benchmark bounds")

    :ok = Index.ready?(sha256)

    Enum.map(numbers, fn number ->
      {:ok, normalized} = Source.normalize_number(number)
      {first_us, first} = :timer.tc(fn -> Index.fetch_enterprise(sha256, normalized) end)

      unless match?({:ok, _}, first) or first == {:error, :not_found},
        do: raise("indexed benchmark lookup failed")

      repeated_us =
        Enum.map(1..repeats, fn _ ->
          {us, result} = :timer.tc(fn -> Index.fetch_enterprise(sha256, normalized) end)
          unless result == first, do: raise("indexed benchmark changed between reads")
          us
        end)
        |> Enum.sort()

      parity =
        if directory do
          {us, csv} = :timer.tc(fn -> Source.load(directory, sha256, normalized) end)
          unless csv == first, do: raise("CSV/index bundle mismatch")
          %{csv_ms: us / 1000, csv_parity: true}
        else
          %{csv_parity: :not_checked}
        end

      Map.merge(parity, %{
        enterprise_number: normalized,
        found: match?({:ok, _}, first),
        bundle_sha256:
          first
          |> :erlang.term_to_binary([:deterministic])
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower),
        first_ms: first_us / 1000,
        repeated_median_ms: Enum.at(repeated_us, div(repeats, 2)) / 1000,
        repeated_p95_ms: Enum.at(repeated_us, ceil(repeats * 0.95) - 1) / 1000,
        repeated_max_ms: List.last(repeated_us) / 1000,
        repeats: repeats
      })
    end)
  end
end
