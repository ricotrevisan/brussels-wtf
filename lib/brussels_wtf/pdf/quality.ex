defmodule BrusselsWtf.PDF.Quality do
  @moduledoc "Deterministic, calibrated page-level native-text acceptance measurements."

  def thresholds, do: Application.fetch_env!(:brussels_wtf, :pdf_quality_thresholds)

  def assess(page_texts) when is_list(page_texts) do
    limits = thresholds()

    pages =
      page_texts
      |> Enum.with_index(1)
      |> Enum.map(fn {text, page} -> page(page, text, limits) end)

    %{
      "page_count" => length(pages),
      "pages" => pages,
      "accepted" => Enum.all?(pages, &(&1["decision"] == "accepted")),
      "rejected_pages" =>
        pages |> Enum.reject(&(&1["decision"] == "accepted")) |> Enum.map(& &1["page"]),
      "thresholds" => Map.new(limits, fn {key, value} -> {to_string(key), value} end)
    }
  end

  def language_signals(page_texts) do
    text = page_texts |> Enum.join(" ") |> String.downcase()

    %{
      "fr" => token_hits(text, ~w[conseil communal ordre séance proposition décision publique]),
      "nl" =>
        token_hits(text, ~w[gemeenteraad gemeentelijk agenda zitting voorstel besluit openbaar])
    }
  end

  defp page(number, text, limits) do
    text = text || ""
    trimmed = String.trim(text)
    characters = String.length(trimmed)
    words = length(Regex.scan(~r/[\p{L}\p{N}]+/u, text))
    alphanumeric = length(Regex.scan(~r/[\p{L}\p{N}]/u, text))
    non_space = length(Regex.scan(~r/\S/u, text))
    controls = length(Regex.scan(~r/[\x{0000}-\x{0008}\x{000B}\x{000C}\x{000E}-\x{001F}]/u, text))
    replacements = length(Regex.scan(~r/�/u, text))

    measurements = %{
      "characters" => characters,
      "words" => words,
      "alphanumeric_ratio" => ratio(alphanumeric, non_space),
      "control_ratio" => ratio(controls, max(characters, 1)),
      "replacement_ratio" => ratio(replacements, max(characters, 1)),
      "printable_ratio" => ratio(max(characters - controls, 0), max(characters, 1))
    }

    reasons =
      []
      |> reject_if(measurements["characters"] < limits.min_characters, "too_few_characters")
      |> reject_if(measurements["words"] < limits.min_words, "too_few_words")
      |> reject_if(
        measurements["alphanumeric_ratio"] < limits.min_alphanumeric_ratio,
        "low_alphanumeric_ratio"
      )
      |> reject_if(measurements["control_ratio"] > limits.max_control_ratio, "high_control_ratio")
      |> reject_if(
        measurements["replacement_ratio"] > limits.max_replacement_ratio,
        "replacement_characters"
      )

    %{
      "page" => number,
      "decision" => if(reasons == [], do: "accepted", else: "ocr_required"),
      "reasons" => Enum.reverse(reasons),
      "measurements" => measurements
    }
  end

  defp token_hits(text, tokens), do: Enum.count(tokens, &String.contains?(text, &1))
  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator
  defp reject_if(reasons, true, reason), do: [reason | reasons]
  defp reject_if(reasons, false, _reason), do: reasons
end
