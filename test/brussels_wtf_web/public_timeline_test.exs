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
    assert meeting =~ "Demonstration reference — not evidence of council activity"
    refute meeting =~ "SHA-256"
    assert meeting =~ "Rico Trevisan"
  end

  test "a missing requested variant never leaks another language", %{conn: conn} do
    commune =
      BrusselsWtf.Ingestion.create_commune!(%{
        slug: "locale-gap",
        name: "Locale Gap",
        index_url: "https://example.invalid/locale-gap"
      })

    meeting =
      BrusselsWtf.Council.upsert_meeting!(%{
        commune_id: commune.id,
        municipal_identifier: "incomplete",
        scheduled_on: ~D[2026-09-20]
      })

    BrusselsWtf.Council.upsert_agenda_item!(%{
      council_meeting_id: meeting.id,
      item_number: "1",
      stable_anchor: "agenda-item-1",
      source_wording: "ENGLISH-ONLY-SENTINEL",
      procedural_state: :proposal
    })

    page =
      BrusselsWtf.Council.upsert_meeting_page!(%{
        council_meeting_id: meeting.id,
        citation_url: "https://example.invalid/locale-gap",
        procedural_state: :proposal
      })

    BrusselsWtf.Council.upsert_locale_variant!(%{
      meeting_page_id: page.id,
      locale: "en",
      title: "ENGLISH-ONLY-SENTINEL",
      summary: "ENGLISH-ONLY-SENTINEL",
      provenance: []
    })

    BrusselsWtf.Council.publish_meeting_page!(page)

    response = get(conn, "/meetings/locale-gap/incomplete?lang=fr")
    html = html_response(response, 200)

    assert get_resp_header(response, "content-language") == ["fr"]
    assert html =~ "Contenu indisponible en français"
    refute html =~ "ENGLISH-ONLY-SENTINEL"
  end

  test "a decision state without a stored disposition renders as unknown, never nil", %{
    conn: conn
  } do
    page =
      BrusselsWtf.Council.list_published_meeting_pages!()
      |> Enum.find(&(&1.council_meeting.municipal_identifier == "demo-ixelles"))

    item = List.first(page.council_meeting.agenda_items)

    BrusselsWtf.Council.upsert_agenda_item!(%{
      council_meeting_id: page.council_meeting.id,
      item_number: item.item_number,
      stable_anchor: item.stable_anchor,
      source_wording: item.source_wording,
      procedural_state: :decision
    })

    document = conn |> get("/?lang=en") |> html_response(200) |> LazyHTML.from_document()
    ixelles = document[~s(article[data-commune="ixelles"])] |> LazyHTML.text()

    assert ixelles =~ "Outcome unknown"
    refute ixelles =~ "Decision: nil"
  end

  test "an exact page locale never substitutes for missing item coverage", %{conn: conn} do
    commune =
      BrusselsWtf.Ingestion.create_commune!(%{
        slug: "item-locale-gap",
        name: "Item Locale Gap",
        index_url: "https://example.invalid/item-locale-gap"
      })

    meeting =
      BrusselsWtf.Council.upsert_meeting!(%{
        commune_id: commune.id,
        municipal_identifier: "item-incomplete",
        scheduled_on: ~D[2026-09-21]
      })

    item =
      BrusselsWtf.Council.upsert_agenda_item!(%{
        council_meeting_id: meeting.id,
        item_number: "1",
        stable_anchor: "agenda-item-1",
        source_wording: "ITEM-EN-SOURCE",
        procedural_state: :proposal
      })

    BrusselsWtf.Council.upsert_proposal!(%{
      agenda_item_id: item.id,
      statement: "ITEM-EN-SOURCE"
    })

    BrusselsWtf.Council.upsert_coverage_variant!(%{
      agenda_item_id: item.id,
      locale: "en",
      title: "ITEM-EN-TITLE",
      summary: "ITEM-EN-SUMMARY",
      proposal_summary: "ITEM-EN-SUMMARY",
      provenance: []
    })

    page =
      BrusselsWtf.Council.upsert_meeting_page!(%{
        council_meeting_id: meeting.id,
        citation_url: "https://example.invalid/item-locale-gap",
        procedural_state: :proposal
      })

    for {locale, title, summary} <- [
          {"fr", "PAGE-FR-TITLE", "PAGE-FR-SUMMARY"},
          {"en", "PAGE-EN-TITLE", "PAGE-EN-SUMMARY"}
        ] do
      BrusselsWtf.Council.upsert_locale_variant!(%{
        meeting_page_id: page.id,
        locale: locale,
        title: title,
        summary: summary,
        provenance: []
      })
    end

    BrusselsWtf.Council.publish_meeting_page!(page)

    document =
      conn
      |> get("/meetings/item-locale-gap/item-incomplete?lang=fr")
      |> html_response(200)
      |> LazyHTML.from_document()

    article = document["article#agenda-item-1"] |> LazyHTML.text()
    assert LazyHTML.text(document["h1"]) =~ "PAGE-FR-TITLE"
    assert article =~ "Contenu du point indisponible en français"
    refute article =~ "PAGE-FR-SUMMARY"
    refute article =~ "ITEM-EN"
  end

  test "meeting state renders unknown when a disposition record is absent", %{conn: conn} do
    page =
      BrusselsWtf.Council.list_published_meeting_pages!()
      |> Enum.find(&(&1.council_meeting.municipal_identifier == "demo-ixelles"))

    item = List.first(page.council_meeting.agenda_items)

    BrusselsWtf.Council.upsert_agenda_item!(%{
      council_meeting_id: page.council_meeting.id,
      item_number: item.item_number,
      stable_anchor: item.stable_anchor,
      source_wording: item.source_wording,
      procedural_state: :decision
    })

    document =
      conn
      |> get("/meetings/ixelles/demo-ixelles?lang=en")
      |> html_response(200)
      |> LazyHTML.from_document()

    article = document["article#agenda-item-mobility-1"] |> LazyHTML.text()
    assert article =~ "Outcome unknown"
    refute article =~ "Decision:"
  end

  test "a stored disposition wins over a stale non-decision procedural state", %{conn: conn} do
    page =
      BrusselsWtf.Council.list_published_meeting_pages!()
      |> Enum.find(&(&1.council_meeting.municipal_identifier == "demo-brussels"))

    item = List.first(page.council_meeting.agenda_items)

    BrusselsWtf.Council.upsert_agenda_item!(%{
      council_meeting_id: page.council_meeting.id,
      item_number: item.item_number,
      stable_anchor: item.stable_anchor,
      source_wording: item.source_wording,
      procedural_state: :unknown
    })

    document =
      conn
      |> get("/meetings/city-of-brussels/demo-brussels?lang=en")
      |> html_response(200)
      |> LazyHTML.from_document()

    article = document["article#agenda-item-administration-3"] |> LazyHTML.text()
    assert article =~ "Decision: approved"
    refute article =~ "Outcome unknown"
  end

  test "stored proposal and final-decision copy remain distinct", %{conn: conn} do
    html =
      conn
      |> get("/meetings/city-of-brussels/demo-brussels?lang=en")
      |> html_response(200)

    assert html =~ "The synthetic demonstration item was proposed"
    assert html =~ "The documented synthetic disposition is approved"
    assert html =~ "Decision: approved"
    refute html =~ "Decision: nil"
  end

  test "dossier references are real links to a stored dossier timeline", %{conn: conn} do
    timeline = conn |> get("/?lang=en") |> html_response(200)
    assert timeline =~ ~s(href="/dossiers/demo-public-space?lang=en")

    dossier =
      conn |> recycle() |> get("/dossiers/demo-public-space?lang=en") |> html_response(200)

    assert dossier =~ "Dossier timeline"
    assert dossier =~ "Ixelles demonstration meeting"
    assert dossier =~ "Uccle demonstration meeting"
    assert dossier =~ "Rico Trevisan"
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
