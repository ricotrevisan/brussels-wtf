defmodule BrusselsWtf.TED.CorrectionChain do
  @moduledoc """
  Selects one terminal result from a complete, bounded set of extracted notices.

  This does not discover notices or establish completeness. The acquisition
  caller must check all versions and reverse correction references in TED and
  retain those search receipts. Missing predecessors, forks and mixed procedures
  fail closed. A terminal no-winner result never falls back to an older award.
  """

  def select(notices) when is_list(notices) and length(notices) in 1..20 do
    with true <- Enum.all?(notices, &valid?/1),
         versions = Enum.map(notices, &key/1),
         true <- length(Enum.uniq(versions)) == length(versions),
         true <- length(Enum.uniq_by(notices, & &1.publication_number)) == length(notices),
         [_] <- Enum.uniq_by(notices, &{&1.procedure_id, &1.lot_id, &1.buyer}),
         by_id = Map.new(notices, &{key(&1), &1}),
         true <- Enum.all?(notices, &valid_predecessor?(&1, by_id)),
         [first] <- Enum.filter(notices, &is_nil(&1.correction_of)),
         children = Enum.group_by(notices, & &1.correction_of),
         true <- Enum.all?(children, fn {_, group} -> length(group) == 1 end),
         {:ok, ordered} <- walk(first, children, []),
         true <- length(ordered) == length(notices) do
      {:ok, %{latest: List.last(ordered), history: Enum.drop(ordered, -1)}}
    else
      _ -> {:error, :incomplete_or_ambiguous_correction_chain}
    end
  end

  def select(_), do: {:error, :incomplete_or_ambiguous_correction_chain}

  defp valid?(%{
         notice_id: id,
         version: version,
         publication_number: publication,
         procedure_id: procedure,
         lot_id: lot,
         buyer: buyer,
         published_on: %Date{},
         correction_of: previous,
         status: status
       }) do
    Enum.all?([id, version, publication, procedure, lot], &(is_binary(&1) and &1 != "")) and
      Regex.match?(~r/\A[0-9]{2}\z/, version) and version != "00" and
      is_map(buyer) and (is_nil(previous) or is_binary(previous)) and
      status in [:awarded, :not_awarded]
  end

  defp valid?(_), do: false
  defp key(notice), do: notice.notice_id <> "-" <> notice.version
  defp valid_predecessor?(%{correction_of: nil}, _), do: true

  defp valid_predecessor?(notice, by_id) do
    case Map.fetch(by_id, notice.correction_of) do
      {:ok, previous} ->
        key(notice) != key(previous) and
          (notice.notice_id != previous.notice_id or
             String.to_integer(notice.version) > String.to_integer(previous.version)) and
          Date.compare(previous.published_on, notice.published_on) != :gt

      :error ->
        false
    end
  end

  defp walk(notice, children, accumulated) do
    if Enum.any?(accumulated, &(key(&1) == key(notice))) do
      {:error, :cycle}
    else
      case Map.get(children, key(notice), []) do
        [] -> {:ok, Enum.reverse([notice | accumulated])}
        [next] -> walk(next, children, [notice | accumulated])
      end
    end
  end
end
