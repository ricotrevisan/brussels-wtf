defmodule BrusselsWtf.UccleAgendaEvidence do
  @moduledoc "Checks normalized Uccle evidence against the text it claims to cite."

  import ExUnit.Assertions

  def assert_on_cited_pages(normalized, text) do
    proposals = Enum.flat_map(normalized["items"], &Map.get(&1, "proposals", []))
    assert proposals != []
    total = text |> pages() |> length()

    for proposal <- proposals do
      evidence = proposal["evidence"]
      {first, last, cited_total} = cited_pages(evidence["location"])

      assert cited_total == total
      assert evidence["claim"] == "proposal"
      assert String.contains?(page(text, first), squish(evidence["excerpt"]))
      assert String.starts_with?(proposal["text"], evidence["excerpt"])

      if last do
        assert last == first + 1
        remainder = proposal["text"] |> String.replace_prefix(evidence["excerpt"], "") |> squish()
        assert remainder != ""
        assert String.contains?(page(text, last), remainder)
      else
        assert proposal["text"] == evidence["excerpt"]
      end
    end

    length(proposals)
  end

  defp pages(text) do
    pages = String.split(text, "\f")
    if List.last(pages) == "", do: Enum.drop(pages, -1), else: pages
  end

  defp page(text, number), do: text |> pages() |> Enum.at(number - 1) |> squish()

  defp squish(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp cited_pages(location) do
    case Regex.run(~r/pages? (\d+)(?:-(\d+))?\/(\d+)$/, location) do
      [_, first, "", total] ->
        {String.to_integer(first), nil, String.to_integer(total)}

      [_, first, last, total] ->
        {String.to_integer(first), String.to_integer(last), String.to_integer(total)}
    end
  end
end
