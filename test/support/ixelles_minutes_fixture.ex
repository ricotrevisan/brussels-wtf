defmodule BrusselsWtf.Test.IxellesMinutesFixture do
  @moduledoc """
  Small extracts in the `pdftotext -layout` shape observed in the retained 2026 Ixelles
  minutes. Wording is abbreviated from the public record and member names are replaced;
  the full municipal documents stay private evidence and are never committed.
  """

  @indent String.duplicate(" ", 34)

  def document(points, opts \\ []) do
    date = Keyword.get(opts, :date, ~D[2026-05-21])
    closing = Keyword.get(opts, :closing, true)

    header(date) <>
      Enum.map_join(points, "\n", &point(&1, date)) <>
      if(closing,
        do:
          "\n                 Levée de la séance à 21:15\n                 Opheffing van de zitting om 21:15\n",
        else: "\n"
      ) <>
      footer(date, 1, 2) <> "\f"
  end

  def header(date) do
    """
                                                                                     COMMUNE D'IXELLES
                                                                                      GEMEENTE ELSENE
                                                     CONSEIL COMMUNAL DU #{date.day} #{french_month(date)} #{date.year}
                                                      GEMEENTERAAD VAN #{date.day} #{dutch_month(date)} #{date.year}


                                                                  PROCÈS VERBAL
                                                                 PROCES-VERBAAL

                                                    SÉANCE PUBLIQUE - OPENBARE ZITTING


        Affaires générales - Algemene zaken

    """
  end

  @doc "Renders one point. `:lines` are verbatim body lines between heading and Dutch title."
  def point(attrs, date \\ ~D[2026-05-21]) do
    number = Map.fetch!(attrs, :number)
    identifier = Map.get(attrs, :identifier, identifier(date, number))
    [first | rest] = attrs |> Map.fetch!(:wording) |> List.wrap()

    heading =
      [
        "    #{identifier}             #{first}"
        | Enum.map(rest, &(@indent <> &1))
      ]

    (heading ++
       [""] ++
       Enum.map(Map.get(attrs, :lines, []), &indented/1) ++
       [
         "",
         @indent <> Map.get(attrs, :dutch_title, "Nederlandse tekst van punt #{number}."),
         ""
       ] ++
       Enum.map(Map.get(attrs, :dutch_lines, []), &indented/1) ++ ["", ""])
    |> Enum.join("\n")
  end

  def identifier(date, number) do
    day = date.day |> Integer.to_string() |> String.pad_leading(2, "0")
    month = date.month |> Integer.to_string() |> String.pad_leading(2, "0")
    padded = number |> Integer.to_string() |> String.pad_leading(4, "0")
    "#{day}.#{month}.#{date.year}/A/#{padded}"
  end

  def footer(date, page, total) do
    day = date.day |> Integer.to_string() |> String.pad_leading(2, "0")
    month = date.month |> Integer.to_string() |> String.pad_leading(2, "0")

    """


    Conseil communal - #{day}.#{month}.#{date.year} - Procès verbal public
    Gemeenteraad - #{day}.#{month}.#{date.year} - Openbaar proces-verbaal                                                #{page}/#{total}
    """
  end

  def approved(voters) do
    %{
      lines: ["Le Conseil approuve.", "#{voters} votants : #{voters} votes positifs."],
      dutch_lines: ["De Raad keurt goed.", "#{voters} stemmers : #{voters} positieve stemmen."]
    }
  end

  defp indented(""), do: ""
  defp indented(line), do: @indent <> line

  defp french_month(%{month: 5}), do: "MAI"
  defp french_month(%{month: 3}), do: "MARS"
  defp french_month(%{month: 1}), do: "JANVIER"
  defp dutch_month(%{month: 5}), do: "MEI"
  defp dutch_month(%{month: 3}), do: "MAART"
  defp dutch_month(%{month: 1}), do: "JANUARI"
end
