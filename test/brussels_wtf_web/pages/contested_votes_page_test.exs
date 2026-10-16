defmodule BrusselsWtfWeb.ContestedVotesPageTest do
  use BrusselsWtfWeb.ConnCase, async: false

  alias BrusselsWtf.Council

  @path "/coverage/contested-votes"

  test "lists contested decisions newest first with commune, date, linked item, disposition and counts",
       %{conn: conn} do
    seed_meeting!("ixelles", "older", ~D[2026-03-02], [
      {:rejected, %{votes_for: 10, votes_against: 20, abstentions: 4}}
    ])

    seed_meeting!("forest", "newer", ~D[2026-05-04], [
      {:approved, %{votes_for: 23, votes_against: 1, abstentions: 10}},
      {:approved, %{votes_for: 30, votes_against: 0, abstentions: 2}},
      {:approved, %{votes_for: 38, votes_against: 0, abstentions: 0}},
      {:approved, %{votes_for: 37}},
      {:approved, %{}}
    ])

    for {locale, heading, commune, disposition} <- [
          {"en", "Contested votes", "Forest", "approved"},
          {"fr", "Votes contestés", "Forest", "approuvée"},
          {"nl", "Betwiste stemmingen", "Vorst", "goedgekeurd"}
        ] do
      document = conn |> recycle() |> get("#{@path}?lang=#{locale}") |> document()

      assert LazyHTML.text(document["h1"]) == heading
      rows = Enum.to_list(document["#contested-votes tbody tr"])

      # Unanimous and incomplete tallies are never listed.
      assert length(rows) == 3

      assert Enum.map(rows, &LazyHTML.attribute(&1, "data-commune")) ==
               [["forest"], ["forest"], ["ixelles"]]

      [first | _] = rows
      cells = first["td"] |> Enum.map(&(LazyHTML.text(&1) |> String.trim()))

      assert cells == [
               commune,
               "2026-05-04",
               "forest newer item-1 #{locale}",
               disposition,
               "23",
               "1",
               "10"
             ]

      href = first["a"] |> LazyHTML.attribute("href") |> List.first()
      uri = URI.parse(href)
      assert uri.path == "/meetings/forest/newer"
      assert uri.fragment == "item-1"
      assert Plug.Conn.Query.decode(uri.query)["lang"] == locale
    end
  end

  test "filters by the reader's commune selection", %{conn: conn} do
    seed_meeting!("ixelles", "ix", ~D[2026-03-02], [
      {:approved, %{votes_for: 10, votes_against: 2, abstentions: 0}}
    ])

    seed_meeting!("uccle", "uc", ~D[2026-04-02], [
      {:approved, %{votes_for: 10, votes_against: 0, abstentions: 3}}
    ])

    document =
      conn
      |> get("#{@path}?lang=en&communes_submitted=1&commune[]=uccle")
      |> document()

    assert LazyHTML.attribute(document["#contested-votes tbody tr"], "data-commune") == ["uccle"]

    assert LazyHTML.attribute(document[~s(input[name="commune[]"]:checked)], "value") == [
             "uccle"
           ]

    empty =
      conn
      |> recycle()
      |> get("#{@path}?lang=fr&communes_submitted=1&commune[]=forest")
      |> document()

    assert Enum.to_list(empty["#contested-votes tbody tr"]) == []
    assert LazyHTML.text(empty["[data-contested-empty]"]) =~ "Aucun vote contesté"
  end

  test "paginates 25 decisions per page and keeps language and communes in pager links", %{
    conn: conn
  } do
    seed_meeting!(
      "city-of-brussels",
      "many",
      ~D[2026-06-01],
      for(_ <- 1..26, do: {:approved, %{votes_for: 10, votes_against: 1, abstentions: 0}})
    )

    selected = "lang=nl&communes_submitted=1&commune[]=city-of-brussels"
    first = conn |> get("#{@path}?#{selected}") |> document()

    assert Enum.count(first["#contested-votes tbody tr"]) == 25
    assert Enum.to_list(first[~s(a[rel="prev"])]) == []
    next = first[~s(a[rel="next"])] |> LazyHTML.attribute("href") |> List.first()
    assert LazyHTML.text(first[~s(a[rel="next"])]) == "Volgende pagina"

    params = Plug.Conn.Query.decode(URI.parse(next).query)
    assert URI.parse(next).path == @path
    assert params["page"] == "2"
    assert params["lang"] == "nl"
    assert params["commune"] == ["city-of-brussels"]

    second = conn |> recycle() |> get(next) |> document()
    assert Enum.count(second["#contested-votes tbody tr"]) == 1
    assert Enum.to_list(second[~s(a[rel="next"])]) == []
    assert [_prev] = Enum.to_list(second[~s(a[rel="prev"])])

    for malformed <- ["page=abc", "page=0", "page[]=2"] do
      fallback = conn |> recycle() |> get("#{@path}?#{selected}&#{malformed}") |> document()
      assert Enum.count(fallback["#contested-votes tbody tr"]) == 25
    end
  end

  test "a withdrawn meeting page is not listed", %{conn: conn} do
    page =
      seed_meeting!("ixelles", "withdrawn", ~D[2026-03-02], [
        {:approved, %{votes_for: 10, votes_against: 2, abstentions: 0}}
      ])

    Ash.Seed.update!(page, %{publication_status: :draft, withdrawn_at: DateTime.utc_now()})

    document = conn |> get("#{@path}?lang=en") |> document()
    assert Enum.to_list(document["#contested-votes tbody tr"]) == []
  end

  test "the overview links to the contested votes view", %{conn: conn} do
    document = conn |> get("/?lang=en") |> document()

    assert Enum.any?(
             LazyHTML.attribute(document["a"], "href"),
             &String.starts_with?(&1, @path <> "?")
           )
  end

  defp document(conn), do: conn |> html_response(200) |> LazyHTML.from_document()

  defp seed_meeting!(slug, identifier, date, decisions) do
    commune =
      BrusselsWtf.Ingestion.create_commune!(%{
        slug: slug,
        name: BrusselsWtf.Communes.configuration!(slug).name,
        index_url: "https://example.invalid/#{slug}"
      })

    meeting =
      Council.upsert_meeting!(%{
        commune_id: commune.id,
        municipal_identifier: identifier,
        scheduled_on: date
      })

    page =
      Council.upsert_meeting_page!(%{
        council_meeting_id: meeting.id,
        citation_url: "https://example.invalid/#{slug}",
        procedural_state: :decision
      })

    for {{disposition, votes}, number} <- Enum.with_index(decisions, 1) do
      item =
        Council.upsert_rendered_agenda_item!(%{
          council_meeting_id: meeting.id,
          item_number: "#{number}",
          stable_anchor: "item-#{number}",
          source_wording: "Synthetic contested fixture",
          procedural_state: :decision
        })

      Council.upsert_proposal!(%{
        agenda_item_id: item.id,
        text: "Synthetic contested fixture",
        status: :proposed,
        render_key: "contested-test"
      })

      decision =
        Council.upsert_decision!(
          Map.merge(
            %{
              agenda_item_id: item.id,
              render_key: "contested-test",
              disposition: disposition,
              statement: "Synthetic decision fixture"
            },
            votes
          )
        )

      Council.mark_agenda_item_decided!(item, %{
        current_decision_id: decision.id,
        outcome: disposition
      })

      for locale <- ~w(fr nl en) do
        Council.upsert_coverage_variant!(%{
          agenda_item_id: item.id,
          locale: locale,
          title: "#{slug} #{identifier} item-#{number} #{locale}",
          summary: "Synthetic contested fixture",
          proposal_summary: "Synthetic contested fixture",
          decision_summary: "Synthetic decision fixture",
          provenance: []
        })
      end
    end

    BrusselsWtf.Seeds.PublicTimeline.publish_for_seed!(page)
  end
end
