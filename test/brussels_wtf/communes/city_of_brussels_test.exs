defmodule BrusselsWtf.Communes.CityOfBrusselsTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Communes.CityOfBrussels

  @index_url "https://www.brussels.be/agenda-reports-and-motions-city-council?field_date_document_value=2026"

  test "discovers exact meeting sources and base and supplement listings from the year index" do
    assert {:ok, locators} = CityOfBrussels.discover(fixture("year_index.html"), @index_url)

    assert Enum.map(locators, &{&1.meeting_identifier, &1.role, &1.language, &1.url}) == [
             {"2026-06-29", :agenda, :fr,
              "https://www.brussels.be/sites/default/files/OJ29062026.pdf"},
             {"2026-06-29", :document_listing, :bilingual,
              "https://www.brussels.be/show_documents/29-06-2026"},
             {"2026-06-29", :supplement, :fr,
              "https://www.brussels.be/sites/default/files/OJsupp29062026.pdf"},
             {"2026-06-29", :document_listing, :bilingual,
              "https://www.brussels.be/show_documents/29-06-2026s"},
             {"2026-06-08", :addendum, :fr,
              "https://www.brussels.be/sites/default/files/AddendumSP.pdf"},
             {"2026-06-08", :agenda, :fr,
              "https://www.brussels.be/sites/default/files/OJSP08062026.pdf"},
             {"2026-06-08", :document_listing, :bilingual,
              "https://www.brussels.be/show_documents/08-06-2026"},
             {"2026-06-08", :supplement, :fr,
              "https://www.brussels.be/sites/default/files/OJsup08062026.pdf"},
             {"2026-06-08", :document_listing, :bilingual,
              "https://www.brussels.be/show_documents/08-06-2026s"}
           ]

    assert Enum.all?(locators, &(&1.parent_index_url == @index_url))
    assert Enum.all?(Enum.take(locators, 4), &(&1.scheduled_on == ~D[2026-06-29]))
  end

  test "discovers every exact item page from base and supplement listings" do
    base_parent = parent(:document_listing, "https://www.brussels.be/show_documents/29-06-2026")

    assert {:ok, base_items} =
             CityOfBrussels.discover_children(fixture("base_listing.html"), base_parent)

    assert Enum.map(base_items, &{&1.role, &1.item_identifier, &1.url}) == [
             {:item_listing, "003",
              "https://www.brussels.be/show_documents/29-06-2026/29 06 2026 OJ point_punt (003)"},
             {:item_listing, "004",
              "https://www.brussels.be/show_documents/29-06-2026/29 06 2026 OJ point_punt (004)"}
           ]

    supplement_parent =
      parent(
        :document_listing,
        "https://www.brussels.be/show_documents/29-06-2026s"
      )

    assert {:ok, supplement_items} =
             CityOfBrussels.discover_children(
               fixture("supplement_listing.html"),
               supplement_parent
             )

    assert Enum.map(supplement_items, &{&1.role, &1.item_identifier}) == [
             {:item_listing, "114"},
             {:item_listing, "115"}
           ]

    assert Enum.all?(base_items ++ supplement_items, fn locator ->
             locator.meeting_identifier == "2026-06-29" and
               locator.scheduled_on == ~D[2026-06-29] and
               locator.language == :bilingual
           end)
  end

  test "discovers separate French and Dutch attachments without synthesizing their filenames" do
    parent =
      parent(:item_listing, "https://www.brussels.be/show_documents/29-06-2026")
      |> Map.merge(%{
        url: "https://www.brussels.be/show_documents/29-06-2026/29 06 2026 OJ point_punt (003)",
        item_identifier: "003"
      })

    assert {:ok, attachments} =
             CityOfBrussels.discover_children(fixture("base_item_003.html"), parent)

    assert Enum.map(attachments, &{&1.language, &1.observed_label, &1.url}) == [
             {:fr, "003_Arrêté Conseil.pdf",
              "https://www.brussels.be/sites/default/files/bxl/workflow/29-06-2026/29 06 2026 OJ point_punt (003)/003_Arrêté Conseil.pdf"},
             {:nl, "003_Raadsbesluit.pdf",
              "https://www.brussels.be/sites/default/files/bxl/workflow/29-06-2026/29 06 2026 OJ point_punt (003)/003_Raadsbesluit.pdf"}
           ]

    assert Enum.all?(attachments, fn locator ->
             locator.role == :supporting_document and
               locator.item_identifier == "003" and
               locator.parent_index_url == parent.url
           end)

    refute Enum.any?(attachments, &String.ends_with?(&1.url, "/Procedure.pdf"))
  end

  test "classifies language markers on supplement attachments and retains every explicit locator" do
    parent =
      parent(:item_listing, "https://www.brussels.be/show_documents/29-06-2026s")
      |> Map.merge(%{
        url: "https://www.brussels.be/show_documents/29-06-2026s/29 06 2026 OJ point_punt (114)",
        item_identifier: "114"
      })

    assert {:ok, attachments} =
             CityOfBrussels.discover_children(fixture("supplement_item_114.html"), parent)

    assert Enum.map(attachments, &{&1.language, &1.observed_label}) == [
             {:fr, "114_Arrêté Conseil.pdf"},
             {:nl, "114_Nieuw huishoudelijk reglement van de Gemeenteraad NL.pdf"},
             {:fr, "114_Nouveau règlement d'ordre intérieur du Conseil communal FR.pdf"},
             {:nl, "114_Raadsbesluit.pdf"}
           ]
  end

  test "fails closed for unrecognizable or malformed authoritative pages" do
    assert {:error, {:invalid_index, :missing_meeting_sections}} =
             CityOfBrussels.discover("<html><p>temporarily empty</p></html>", @index_url)

    malformed_listing = """
    <h1>Documents from 29-06-2026</h1>
    <a href="/show_documents/29-06-2026/point_punt-unknown">point_punt (unknown)</a>
    """

    assert {:error, {:invalid_listing, :invalid_item_identifier}} =
             CityOfBrussels.discover_children(
               malformed_listing,
               parent(:document_listing, "https://www.brussels.be/show_documents/29-06-2026")
             )

    assert {:error, {:invalid_item_listing, :no_authoritative_attachments}} =
             CityOfBrussels.discover_children(
               "<h1>Documents for item 003</h1><a href='/show_documents/29-06-2026'>Back</a>",
               parent(:item_listing, "https://www.brussels.be/show_documents/29-06-2026")
               |> Map.put(:item_identifier, "003")
             )
  end

  defp fixture(name) do
    Path.expand("../../support/fixtures/city_of_brussels/adapter/#{name}", __DIR__)
    |> File.read!()
  end

  defp parent(role, url) do
    %{
      url: url,
      meeting_identifier: "2026-06-29",
      scheduled_on: ~D[2026-06-29],
      role: role,
      language: :bilingual,
      observed_label: "Captured listing",
      parent_index_url: @index_url,
      item_identifier: nil
    }
  end
end
