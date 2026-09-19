defmodule BrusselsWtfWeb.PublicProfilePageTest do
  use BrusselsWtfWeb.ConnCase, async: false

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Test.PublicProfileFixture

  setup do
    previous = Application.fetch_env!(:brussels_wtf, :suggestions)
    Application.put_env(:brussels_wtf, :suggestions, Keyword.put(previous, :enabled, true))
    on_exit(fn -> Application.put_env(:brussels_wtf, :suggestions, previous) end)

    company = PublicProfileFixture.company!()

    Identity.record_legal_entity_name!(%{
      legal_entity_id: company.id,
      cbe_release_id: company.cbe_release_id,
      name: "PRIVATE CANDIDATE TRADING NAME",
      kind: :trading,
      language: "en"
    })

    fixture = PublicProfileFixture.load!()
    %{person: person} = PublicProfileFixture.publish_person!(fixture, "Alex Public", 42)
    %{person: retired_public} = PublicProfileFixture.publish_person!(fixture, "Prior Public", 43)
    private_person = record_private_person!("PRIVATE ONLY PERSON")
    retired_private = record_private_person!("PRIVATE RETIRED PERSON")
    actor = %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}
    Identity.merge_people!(retired_public.id, person.id, "PUBLIC MERGE NOTE", actor)
    Identity.merge_people!(retired_private.id, person.id, "PRIVATE MERGE NOTE", actor)

    {:ok,
     company: company,
     person: person,
     private_person: private_person,
     retired_public: retired_public,
     retired_private: retired_private}
  end

  test "an exact company route renders the closed CBE profile, citation, and embedded forms", %{
    conn: conn,
    company: company
  } do
    response = get(conn, "/companies/0123456749?lang=en")
    html = html_response(response, 200)
    document = LazyHTML.from_document(html)

    assert get_resp_header(response, "content-language") == ["en"]
    assert LazyHTML.text(document["h1"]) =~ "Public Example ASBL"
    assert html =~ "Enterprise number"
    assert html =~ "0123456749"
    assert html =~ "Active"
    assert html =~ "Crossroads Bank for Enterprises (CBE) Open Data"
    assert html =~ "2026-08-29"
    assert html =~ String.duplicate("b", 64)

    assert LazyHTML.attribute(document[~s(link[rel="canonical"])], "href") == [
             "/companies/0123456749"
           ]

    for locale <- ~w(fr nl en) do
      assert html =~ ~s(rel="alternate" hreflang="#{locale}")
      assert html =~ ~s(href="/companies/0123456749?lang=#{locale}")
    end

    assert html =~ ~s(action="/companies/0123456749/suggestions/ownership")
    assert html =~ ~s(action="/companies/0123456749/suggestions/correction")
    assert length(LazyHTML.to_tree(document[~s(form[action*="/suggestions/"])])) == 2

    assert length(
             LazyHTML.to_tree(
               document[~s(form[action*="/suggestions/"] input[name="_csrf_token"])]
             )
           ) == 2

    assert length(
             LazyHTML.to_tree(document[~s(form[action*="/suggestions/"] input[name="website"])])
           ) == 2

    assert html =~ "Private contact (optional)"

    refute html =~ company.id
    refute html =~ "PRIVATE"
    refute html =~ "CANDIDATE"
  end

  test "company routes reject formatted, invalid, unknown, and invalid-release entities", %{
    conn: conn
  } do
    PublicProfileFixture.company!(%{
      enterprise_number: "0202239951",
      registered_name: "Invalid Release SA",
      sha256: "invalid"
    })

    for number <- ["0123.456.749", "0123456748", "not-a-number", "0202239951"] do
      assert conn |> recycle() |> get("/companies/#{number}") |> html_response(404)
    end
  end

  test "a verified person page uses neutral localized wording, citations, dates, and correction form",
       %{
         conn: conn,
         person: person
       } do
    response = get(conn, "/people/#{person.id}?lang=en")
    html = html_response(response, 200)
    document = LazyHTML.from_document(html)

    assert LazyHTML.text(document["h1"]) =~ "Alex Public"
    assert html =~ "Public mandate"
    assert html =~ "Ixelles"
    assert html =~ ~s(href="https://www.ixelles.be/uploads/conseil/pv/267.pdf")
    assert html =~ "decision 267"
    assert html =~ ~s(datetime="2025-01-01")
    assert html =~ ~s(action="/people/#{person.id}/suggestions/correction")
    assert length(LazyHTML.to_tree(document[~s(form[action*="/suggestions/"])])) == 1

    assert LazyHTML.attribute(document[~s(link[rel="canonical"])], "href") == [
             "/people/#{person.id}"
           ]

    refute html =~ "PRIVATE"
    refute html =~ "CANDIDATE"
    refute html =~ "relationship:ixelles"
  end

  test "profile wording is fixed in French, Dutch, and English", %{conn: conn, person: person} do
    for {locale, expected_kind, expected_correction} <- [
          {"fr", "Mandat public", "Suggérer une correction"},
          {"nl", "Openbaar mandaat", "Een correctie voorstellen"},
          {"en", "Public mandate", "Suggest a correction"}
        ] do
      response = conn |> recycle() |> get("/people/#{person.id}?lang=#{locale}")
      html = html_response(response, 200)

      assert get_resp_header(response, "content-language") == [locale]
      assert html =~ expected_kind
      assert html =~ expected_correction
      assert html =~ ~s(href="/people/#{person.id}?lang=#{locale}")
      refute html =~ "Rico Trevisan"
      refute html =~ "PRIVATE"
    end
  end

  test "private-only people and invalid identifiers fail closed", %{
    conn: conn,
    private_person: private_person
  } do
    assert conn |> get("/people/#{private_person.id}") |> html_response(404)
    assert conn |> recycle() |> get("/people/#{Ecto.UUID.generate()}") |> html_response(404)
    assert conn |> recycle() |> get("/people/not-a-uuid") |> html_response(404)
  end

  test "only a previously public retired person redirects permanently and keeps locale", %{
    conn: conn,
    person: person,
    retired_public: retired_public,
    retired_private: retired_private
  } do
    private_response = get(conn, "/people/#{retired_private.id}?lang=nl")
    assert html_response(private_response, 404)

    response = conn |> recycle() |> get("/people/#{retired_public.id}?lang=nl")
    assert response.status == 308
    assert get_resp_header(response, "location") == ["/people/#{person.id}?lang=nl"]
    refute response.resp_body =~ "Prior Public"
  end

  test "disabled suggestions keep eligible profiles public but hide every form", %{
    conn: conn,
    person: person
  } do
    previous = Application.fetch_env!(:brussels_wtf, :suggestions)
    Application.put_env(:brussels_wtf, :suggestions, Keyword.put(previous, :enabled, false))

    company_html = conn |> get("/companies/0123456749") |> html_response(200)
    person_html = conn |> recycle() |> get("/people/#{person.id}") |> html_response(200)
    refute company_html =~ "/suggestions/"
    refute person_html =~ "/suggestions/"
  end

  defp record_private_person!(legal_name) do
    Identity.record_person!(%{
      legal_name: legal_name,
      explicit_identifier: "private-#{System.unique_integer([:positive])}",
      resolution_basis: :explicit_identifier,
      corroborating_facts: %{"private_address" => "PRIVATE HOME ADDRESS"}
    })
  end
end
