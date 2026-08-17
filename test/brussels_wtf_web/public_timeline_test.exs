defmodule BrusselsWtfWeb.PublicTimelineTest do
  use BrusselsWtfWeb.ConnCase, async: false

  setup do
    BrusselsWtf.Seeds.PublicTimeline.run!()
    :ok
  end

  test "the timeline renders stored coverage for all communes in distinct sections", %{conn: conn} do
    conn = get(conn, "/?lang=en")
    html = html_response(conn, 200)

    document = LazyHTML.from_document(html)
    assert Enum.count(document["main#content"]) == 1
    assert Enum.count(document[~s(nav[aria-label="Language"])]) == 1
    assert Enum.count(document[~s(section[aria-labelledby="coming-up"])]) == 1
    assert Enum.count(document[~s(section[aria-labelledby="decided"])]) == 1
    assert html =~ "Coming up"
    assert html =~ "What they decided"

    for commune <- ["Ixelles", "Uccle", "Forest", "City of Brussels"] do
      assert html =~ commune
    end

    assert html =~ "Proposal"
    assert html =~ "Outcome unknown"
    assert html =~ "Decision: postponed"
    assert html =~ "Decision: approved"
    refute html =~ "Official source linked"
  end

  test "entries and meeting coverage use stable item anchors with citations and provenance", %{
    conn: conn
  } do
    timeline = conn |> get("/?lang=en") |> html_response(200)

    assert timeline =~ ~s(href="/meetings/ixelles/demo-ixelles?lang=en#agenda-item-mobility-1")
    assert timeline =~ "AI-generated"
    assert timeline =~ "machine-translated"
    assert timeline =~ ~s(rel="external")
    assert timeline =~ "Rico Trevisan"

    meeting =
      conn |> recycle() |> get("/meetings/ixelles/demo-ixelles?lang=en") |> html_response(200)

    document = LazyHTML.from_document(meeting)
    assert Enum.count(document["article#agenda-item-mobility-1"]) == 1
    assert Enum.count(document["article#agenda-item-mobility-1 h2"]) == 1
    assert meeting =~ "Proposal"
    assert meeting =~ "Outcome unknown"
    assert meeting =~ "Continuing dossier"
    assert meeting =~ "Retrieved"
    assert meeting =~ "SHA-256"
    assert meeting =~ "Rico Trevisan"
  end

  test "French, Dutch, and English meeting variants keep one resource identity", %{conn: conn} do
    variants = [
      {"fr-BE", "fr", "Réunion de démonstration d’Ixelles"},
      {"nl-BE", "nl", "Demonstratievergadering van Elsene"},
      {"en", "en", "Ixelles demonstration meeting"}
    ]

    Enum.each(variants, fn {query, locale, title} ->
      response = conn |> recycle() |> get("/meetings/ixelles/demo-ixelles?lang=#{query}")
      document = response |> html_response(200) |> LazyHTML.from_document()

      assert get_resp_header(response, "content-language") == [locale]
      assert LazyHTML.text(document["h1"]) =~ title

      assert LazyHTML.attribute(document[~s(link[rel="canonical"])], "href") == [
               "/meetings/ixelles/demo-ixelles"
             ]
    end)
  end

  test "an agenda-item bookmark survives a later stored update", %{conn: conn} do
    page =
      BrusselsWtf.Council.list_published_meeting_pages!()
      |> Enum.find(&(&1.council_meeting.municipal_identifier == "demo-ixelles"))

    item = List.first(page.council_meeting.agenda_items)

    BrusselsWtf.Council.upsert_agenda_item!(%{
      council_meeting_id: page.council_meeting.id,
      item_number: item.item_number,
      stable_anchor: "a-new-anchor-must-not-replace-the-public-one",
      source_wording: "A later stored revision",
      procedural_state: :unknown
    })

    html = conn |> get("/?lang=en") |> html_response(200)
    assert html =~ "#agenda-item-mobility-1"
    refute html =~ "#a-new-anchor-must-not-replace-the-public-one"
  end

  test "explicit language wins, is persisted, and responses cannot be shared across readers", %{
    conn: conn
  } do
    conn =
      conn
      |> put_req_header("accept-language", "nl-BE,nl;q=0.9")
      |> get("/?lang=fr-BE")

    assert get_resp_header(conn, "content-language") == ["fr"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert vary_values(conn) == MapSet.new(["accept-language", "cookie"])

    assert Enum.any?(
             get_resp_header(conn, "set-cookie"),
             &String.contains?(&1, "brussels_wtf_locale=fr")
           )

    assert html_response(conn, 200) =~ "À venir"
  end

  test "persisted language wins over Accept-Language when lang is absent", %{conn: conn} do
    conn =
      conn
      |> put_req_cookie("brussels_wtf_locale", "nl")
      |> put_req_header("accept-language", "fr-BE,fr;q=0.9")
      |> get("/")

    assert get_resp_header(conn, "content-language") == ["nl"]
    assert html_response(conn, 200) =~ "Binnenkort"
  end

  test "Accept-Language is used on first visit and English is the deterministic fallback", %{
    conn: conn
  } do
    dutch = conn |> put_req_header("accept-language", "de;q=1, nl-BE;q=0.8, fr;q=0.7") |> get("/")
    assert get_resp_header(dutch, "content-language") == ["nl"]
    assert html_response(dutch, 200) =~ "Binnenkort"

    english =
      conn
      |> recycle()
      |> put_req_header("accept-language", "de,es;q=0.8")
      |> get("/?lang=not-a-locale")

    assert get_resp_header(english, "content-language") == ["en"]
    assert html_response(english, 200) =~ "Coming up"
  end

  test "commune filtering works without JavaScript and exposes local browser enhancement", %{
    conn: conn
  } do
    html =
      conn
      |> get("/?lang=en&commune[]=ixelles&commune[]=forest")
      |> html_response(200)

    document = LazyHTML.from_document(html)
    entries = document[~s(article[data-commune])]

    assert MapSet.new(LazyHTML.attribute(entries, "data-commune")) ==
             MapSet.new(["ixelles", "forest"])

    assert Enum.count(document[~s(form[method="get"][action="/"][data-reader-communes])]) == 1
    assert Enum.count(document[~s(input[name="commune[]"])]) == 4
  end

  defp vary_values(conn) do
    conn
    |> get_resp_header("vary")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> MapSet.new()
  end
end
