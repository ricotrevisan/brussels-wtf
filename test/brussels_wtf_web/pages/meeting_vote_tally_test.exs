defmodule BrusselsWtfWeb.MeetingVoteTallyTest do
  use BrusselsWtfWeb.ConnCase, async: false

  alias BrusselsWtf.Council

  setup do
    BrusselsWtf.Seeds.PublicTimeline.run!()
    :ok
  end

  defp set_votes!(meeting_id, votes) do
    {:ok, page} = Council.get_published_meeting_page("city-of-brussels", meeting_id)
    item = Enum.find(page.council_meeting.agenda_items, & &1.published?)

    Council.upsert_decision!(
      Map.merge(
        %{
          agenda_item_id: item.id,
          render_key: "synthetic-seed",
          disposition: :approved,
          statement: "Synthetic demonstration final disposition — approved"
        },
        votes
      )
    )

    item
  end

  defp rows(html), do: html |> LazyHTML.from_document() |> Access.get("#vote-tally tbody tr")

  test "a contested decision shows its split and survives the contested filter", %{conn: conn} do
    item =
      set_votes!("demo-brussels", %{votes_for: 23, votes_against: 1, abstentions: 10})

    for {locale, heading, stats} <- [
          {"en", "Vote tally", "Decisions: 1 · unanimous: 0 · contested: 1"},
          {"fr", "Résultats des votes", "Décisions : 1 · unanimes : 0 · contestées : 1"},
          {"nl", "Stemmingsresultaten", "Besluiten: 1 · unaniem: 0 · betwist: 1"}
        ] do
      html =
        conn
        |> get("/meetings/city-of-brussels/demo-brussels?lang=#{locale}")
        |> html_response(200)

      document = LazyHTML.from_document(html)

      assert document["#vote-tally-heading"] |> LazyHTML.text() == heading
      assert document["[data-vote-stats]"] |> LazyHTML.text() |> String.trim() == stats

      assert [row] = Enum.to_list(rows(html))
      assert LazyHTML.attribute(row, "data-vote-status") == ["contested"]
      assert row["a"] |> LazyHTML.attribute("href") == ["#" <> item.stable_anchor]

      assert row["td"] |> Enum.map(&(LazyHTML.text(&1) |> String.trim())) |> Enum.slice(3, 3) ==
               ["23", "1", "10"]

      assert [_bar] = Enum.to_list(row["[role=img]"])

      filtered =
        conn
        |> get("/meetings/city-of-brussels/demo-brussels?lang=#{locale}&votes=contested")
        |> html_response(200)

      assert [_row] = Enum.to_list(rows(filtered))
    end
  end

  test "a decision without a recorded tally renders no tally table", %{conn: conn} do
    html = conn |> get("/meetings/city-of-brussels/demo-brussels?lang=en") |> html_response(200)
    assert Enum.to_list(LazyHTML.from_document(html)["#vote-tally"]) == []
  end

  test "an incomplete tally is not counted as unanimous or contested", %{conn: conn} do
    set_votes!("demo-brussels", %{votes_for: 37})

    html = conn |> get("/meetings/city-of-brussels/demo-brussels?lang=en") |> html_response(200)
    # Nothing complete to tabulate, so the section stays hidden rather than implying unanimity.
    assert Enum.to_list(LazyHTML.from_document(html)["#vote-tally"]) == []
  end
end
