defmodule BrusselsWtfWeb.PlainLanguageHeadlineTest do
  use BrusselsWtfWeb.ConnCase, async: false

  alias BrusselsWtf.Repo

  setup do
    BrusselsWtf.Seeds.PublicTimeline.run!()
    :ok
  end

  defp set_headline!(headline) do
    Repo.query!(
      "UPDATE coverage_variants SET headline = $1 WHERE locale = 'en' AND agenda_item_id IN (SELECT id FROM agenda_items WHERE stable_anchor = 'agenda-item-mobility-1')",
      [headline]
    )
  end

  @path "/meetings/ixelles/demo-ixelles?lang=en"

  test "the headline leads, marked as AI-written, with the official title beneath it", %{
    conn: conn
  } do
    set_headline!("Plain words for this item")

    document = conn |> get(@path) |> html_response(200) |> LazyHTML.from_document()
    row = document["#agenda-item-mobility-1 summary"]

    assert LazyHTML.text(row["[data-headline]"]) =~ "Plain words for this item"
    assert LazyHTML.text(row["[data-official-title]"]) =~ "Ixelles demonstration meeting"
    assert [_label] = LazyHTML.attribute(row["[data-headline] [role=img]"], "aria-label")
  end

  test "without a headline the official title stands alone", %{conn: conn} do
    document = conn |> get(@path) |> html_response(200) |> LazyHTML.from_document()
    row = document["#agenda-item-mobility-1 summary"]

    assert Enum.to_list(row["[data-headline]"]) == []
    assert LazyHTML.text(row) =~ "Ixelles demonstration meeting"
  end
end
