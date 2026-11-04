defmodule BrusselsWtf.Contracts.ForestAgendaRealTest do
  @moduledoc """
  Runs `ForestCouncil` over the complete retained text of real Forest agendas.

  The text stays out of Git because the repository is public. Export each accepted
  `native-text` artifact from the private archive as `<output sha256>.txt`, then run:

      FOREST_AGENDA_REAL_TEXT_DIRECTORY=/private/dir MIX_TEST_PARTITION=_w4 \
        mix test test/contracts/forest_agenda_real_test.exs --include external

  `test/brussels_wtf/processors/forest_council_test.exs` covers the same layouts in CI
  with minimal excerpts.
  """

  use ExUnit.Case, async: true

  alias BrusselsWtf.Processors.ForestCouncil

  @moduletag :external
  @moduletag skip: is_nil(System.get_env("FOREST_AGENDA_REAL_TEXT_DIRECTORY"))

  @september_22 "865a585c9b7cce8d8ede81fbe112cf697741077d6752fcb422c41c18a113ce37"
  @october_13 "d8c4ee867024504725de02fa10e2723e08ff3f672edd8263244220c613edbf9e"
  @september_1_base "ec1d7e50a19241d3293b9178352629f9a2949b13e06373f882ce1a547011e718"
  @september_1_complementary "ee643e2166cdb4178d6aabe9f45f71833b7abb9c7d685c16bf5adb9267ca61be"
  @college_june_25 "28e84a08309bd7be3a3a034cbdbe46b2bd3d452be09cff927e0e1b7c329bc28f"

  defp text(sha256) do
    text =
      System.fetch_env!("FOREST_AGENDA_REAL_TEXT_DIRECTORY")
      |> Path.join("#{sha256}.txt")
      |> File.read!()

    assert BrusselsWtf.Digest.sha256(text) == sha256
    text
  end

  defp pages(text), do: text |> String.split("\f") |> Enum.reject(&(String.trim(&1) == ""))

  defp normalize(text, date, role) do
    ForestCouncil.normalize(%{
      "commune_slug" => "forest",
      "role" => role,
      "meeting_identifier" => date,
      "scheduled_on" => date,
      "text" => text,
      "page_count" => length(pages(text))
    })
  end

  # The 1 September meeting is in the recorded corpus, so the normalizer refuses it.
  # Moving only its date proves the layout rules on the two largest real documents.
  defp moved_to_september_8(text) do
    text
    |> String.replace("DU 1 SEPTEMBRE 2026", "DU 8 SEPTEMBRE 2026")
    |> String.replace("VAN 1 SEPTEMBER 2026", "VAN 8 SEPTEMBER 2026")
    |> String.replace("01.09.2026", "08.09.2026")
  end

  defp assert_every_excerpt_on_its_cited_page(normalized, text) do
    for %{"proposals" => [%{"text" => wording, "evidence" => evidence}]} <- normalized["items"] do
      assert evidence["excerpt"] == wording
      assert ForestCouncil.excerpt_on_cited_pages?(evidence, pages(text))
    end
  end

  defp proposal_count(normalized),
    do: Enum.count(normalized["items"], &Map.has_key?(&1, "proposals"))

  test "22 September 2026: 31 points, 31 cited proposals" do
    text = text(@september_22)
    assert {:ok, normalized} = normalize(text, "2026-09-22", "agenda")
    assert length(normalized["items"]) == 31
    assert proposal_count(normalized) == 31
    assert_every_excerpt_on_its_cited_page(normalized, text)
  end

  test "13 October 2026: 34 points, 32 cited proposals, 2 non-votable points" do
    text = text(@october_13)
    assert {:ok, normalized} = normalize(text, "2026-10-13", "agenda")
    assert length(normalized["items"]) == 34
    assert proposal_count(normalized) == 32

    assert normalized["items"]
           |> Enum.reject(&Map.has_key?(&1, "proposals"))
           |> Enum.map(& &1["item_number"]) == ["33", "34"]

    assert_every_excerpt_on_its_cited_page(normalized, text)
  end

  test "the larger September layouts parse once their date is moved off the corpus meeting" do
    base = @september_1_base |> text() |> moved_to_september_8()
    assert {:ok, normalized} = normalize(base, "2026-09-08", "agenda")
    assert normalized["agenda"]["kind"] == "base"
    assert_every_excerpt_on_its_cited_page(normalized, base)

    complementary = @september_1_complementary |> text() |> moved_to_september_8()
    assert {:ok, normalized} = normalize(complementary, "2026-09-08", "complementary_agenda")
    assert normalized["agenda"]["kind"] == "complementary"
    assert length(normalized["items"]) == 51
    assert_every_excerpt_on_its_cited_page(normalized, complementary)
  end

  test "the real 1 September documents stay out of the sealed corpus meeting" do
    for {sha256, role} <- [
          {@september_1_base, "agenda"},
          {@september_1_complementary, "complementary_agenda"}
        ] do
      assert {:error, {:normalization_ambiguity, %{"reason" => "recorded_corpus_meeting"}}} =
               normalize(text(sha256), "2026-09-01", role)
    end
  end

  test "the Collège agenda served behind a council locator is refused" do
    assert {:error, :processor_unimplemented} =
             normalize(text(@college_june_25), "2026-06-23", "complementary_agenda")

    assert {:error, {:normalization_ambiguity, %{"missing_markers" => missing}}} =
             normalize(text(@college_june_25), "2026-09-08", "complementary_agenda")

    assert "meeting_heading_fr" in missing
  end
end
