defmodule BrusselsWtf.Council.Headline do
  @moduledoc """
  Decides whether a generated plain-language headline may be shown.

  A headline is a convenience above the official title, so a doubtful one is dropped
  rather than blocking publication. The reader then sees the official title alone.
  """

  @max_length 100
  @outcome_words ~r/\b(approuv|adopt|vot[ée]|d[ée]cid|rejet|refus|goedgekeurd|aangenomen|besloten|beslist|verworpen|geweigerd|approved|rejected|decided|voted|passed|joins|rejoint|adh[èe]re|treedt toe|appointed|nomm[ée]|benoemd|aangesteld|accepted|accept[ée]|aanvaard)/iu

  # "Approval of a settlement" reads as settled, so an undecided item cannot lead with procedure.
  @procedural_start ~r/^\s*(adoption|adopt|appointment|designation|acknowledg\w+|granting|grant of|ratification|nomination|d[ée]signation|prise d.acte|octroi|ratification|aanneming|benoeming|aanstelling|aanduiding|kennisneming|toekenning|bekrachtiging)\b/iu
  @approval_words ~r/\b(approval|approve|approbation|approuver|goedkeuring|goedkeuren)\b/iu
  @person_installed ~r/\b(installation|installatie)\b.*\b(mr|ms|mrs|m\.|mme|mevr|dhr)\b/iu

  @doc "True when a translated headline is really the French one, unchanged or nearly so."
  def untranslated?(headline, french) when is_binary(headline) and is_binary(french) do
    String.jaro_distance(String.downcase(headline), String.downcase(french)) > 0.88
  end

  def untranslated?(_headline, _french), do: false

  @doc "Returns the trimmed headline, or nil when it fails a check."
  def accept(headline, source_text, decided?) when is_binary(headline) do
    trimmed = String.trim(headline)

    if trimmed != "" and String.length(trimmed) <= @max_length and
         numbers_from_source?(trimmed, source_text) and
         (decided? or
            not (Regex.match?(@outcome_words, trimmed) or
                   Regex.match?(@procedural_start, trimmed) or
                   Regex.match?(@approval_words, trimmed) or
                   Regex.match?(@person_installed, trimmed))) do
      trimmed
    end
  end

  def accept(_headline, _source_text, _decided?), do: nil

  # Every figure must come from the source. "€43,300" may shorten "43.300,56 EUR",
  # but a figure the source does not contain is never shown.
  defp numbers_from_source?(headline, source_text) do
    source = numbers(source_text || "")

    headline
    |> numbers()
    |> Enum.all?(fn number ->
      Enum.any?(source, &(&1 == number or dropped_decimals?(&1, number)))
    end)
  end

  defp dropped_decimals?(source, number) do
    String.starts_with?(source, number) and byte_size(source) - byte_size(number) == 2
  end

  defp numbers(text) do
    ~r/\d+(?:[ .,\x{00A0}\x{202F}]\d+)*/u
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(&String.replace(&1, ~r/\D/u, ""))
  end
end
