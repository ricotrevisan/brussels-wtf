defmodule BrusselsWtfWeb.MunicipalInstallationPageTest do
  use BrusselsWtfWeb.ConnCase, async: false

  alias BrusselsWtf.Identity
  alias Identity.MunicipalInstallation
  alias BrusselsWtf.MunicipalInstallationArchiveFixture, as: Fixture

  @slugs ~w(ixelles uccle forest city-of-brussels)
  @copy %{
    "en" => {"Dated history", "Installation documented on 2024-12-01; end date not established"},
    "fr" =>
      {"Historique daté", "Installation documentée le 2024-12-01 ; date de fin non établie"},
    "nl" =>
      {"Gedateerde geschiedenis",
       "Installatie gedocumenteerd op 2024-12-01; einddatum niet vastgesteld"}
  }

  setup do
    BrusselsWtf.Archive.Memory.reset()
    BrusselsWtf.Processors.Stub.reset()
    :ok
  end

  test "archived sources become discoverable historical profiles in FR/NL/EN, with exact PDF pages",
       %{conn: conn} do
    for slug <- @slugs, do: Fixture.load!(slug)
    actor = %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}

    assert {:ok, previews} = MunicipalInstallation.preview(@slugs, actor: actor)
    assert Enum.all?(previews, &(&1.eligible >= 2))
    assert Identity.list_public_relationships!() == []
    before = conn |> get("/mandates?lang=en") |> html_response(200)
    refute before =~ "Installation documented"
    refute before =~ "Léa Exemple"

    assert {:ok, reports} =
             MunicipalInstallation.publish(@slugs, actor: actor, max_facts_per_commune: 2)

    assert Enum.all?(reports, &(&1.published_new == 2))
    roles = Identity.list_public_relationships!()
    assert length(roles) == 8

    for {locale, {history, wording}} <- @copy do
      homepage = conn |> recycle() |> get("/mandates?lang=#{locale}") |> html_response(200)
      overview = conn |> recycle() |> get("/?lang=#{locale}") |> html_response(200)
      refute overview =~ "Léa Exemple"
      refute overview =~ "Installation document"
      home = LazyHTML.from_document(homepage)
      assert length(LazyHTML.to_tree(home["#verified-mandates + ul > li"])) == 8
      assert LazyHTML.text(home["#verified-mandates + ul"]) =~ wording

      for role <- roles do
        link = "/people/#{role.subject_id}?lang=#{locale}#fact-#{role.fact_id}"
        assert link in LazyHTML.attribute(home["#verified-mandates + ul a"], "href")
        assert LazyHTML.text(home["#verified-mandates + ul"]) =~ role.role_labels[locale]

        response = conn |> recycle() |> get("/people/#{role.subject_id}?lang=#{locale}")
        html = html_response(response, 200)
        page = LazyHTML.from_document(html)
        fact = page["#fact-#{role.fact_id}"]
        assert get_resp_header(response, "content-language") == [locale]
        assert LazyHTML.text(page["h1"]) == role.subject_name
        assert LazyHTML.text(page["h3"]) == history
        assert String.trim(LazyHTML.text(fact["h4"])) == role.role_labels[locale]
        assert LazyHTML.text(fact) =~ wording

        assert LazyHTML.attribute(page[~s(link[rel="canonical"])], "href") == [
                 "/people/#{role.subject_id}"
               ]

        # Expected source pages come from the synthetic source scenario, not the citation renderer.
        expected_page =
          case role.object_name do
            "Ixelles" -> 4
            "Uccle" -> if(role.subject_name == "Anne Test-Lescot", do: 4, else: 3)
            "Forest" -> 3
            "City of Brussels" -> if(role.subject_name == "Léa Exemple", do: 22, else: 57)
          end

        href = role.authoritative_url <> "#page=#{expected_page}"
        assert LazyHTML.attribute(fact[~s(a[rel="external"])], "href") == [href]
        assert href in LazyHTML.attribute(home[~s(a[rel="external"])], "href")

        for private <- [
              "PRIVATE",
              "secret@example.invalid",
              "42 rue Interdite",
              "010000000",
              "corroborating_facts",
              "identity_evidence",
              "object_key",
              "municipal_installation_v1",
              "2030"
            ] do
          refute html =~ private
          refute homepage =~ private
        end

        refute LazyHTML.text(fact) =~ "Ongoing"
        refute LazyHTML.text(page["h3"]) =~ "Current"
      end
    end

    for slug <- @slugs do
      name = BrusselsWtf.Communes.configuration!(slug).name

      html =
        conn
        |> recycle()
        |> get("/mandates?lang=en&communes_submitted=1&commune[]=#{slug}")
        |> html_response(200)

      home = LazyHTML.from_document(html)
      links = LazyHTML.attribute(home["#verified-mandates + ul a"], "href")

      for role <- roles do
        link = "/people/#{role.subject_id}?lang=en#fact-#{role.fact_id}"
        assert link in links == (role.object_name == name)
      end
    end

    empty =
      conn |> recycle() |> get("/mandates?lang=en&communes_submitted=1") |> html_response(200)

    refute empty =~ ~s(id="verified-mandates")
  end

  test "the mandates directory shows one bounded page and clamps page params", %{conn: conn} do
    for slug <- @slugs, do: Fixture.load!(slug)
    actor = %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}

    assert {:ok, reports} =
             MunicipalInstallation.publish(@slugs, actor: actor, max_facts_per_commune: 2)

    assert Enum.all?(reports, &(&1.published_new == 2))

    for query <- [
          "lang=en",
          "lang=en&page=abc",
          "lang=en&page=0",
          "lang=en&page=-4",
          "lang=en&page[]=2",
          "lang=en&page[deep]=2"
        ] do
      home =
        conn
        |> recycle()
        |> get("/mandates?#{query}")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert length(LazyHTML.to_tree(home["#verified-mandates + ul > li"])) == 8
      assert LazyHTML.attribute(home[~s(a[rel="next"])], "href") == []
      assert LazyHTML.attribute(home[~s(nav[aria-label="Mandate pages"] a)], "href") == []
    end

    beyond =
      conn
      |> recycle()
      |> get("/mandates?lang=en&page=2")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert LazyHTML.to_tree(beyond["#verified-mandates + ul > li"]) == []
    assert LazyHTML.text(beyond) =~ "No verified public mandates"

    prev_href =
      LazyHTML.attribute(beyond[~s(nav[aria-label="Mandate pages"] a[rel="prev"])], "href")
      |> List.first()

    params = URI.parse(prev_href) |> Map.fetch!(:query) |> Plug.Conn.Query.decode()

    assert params == %{
             "lang" => "en",
             "communes_submitted" => "1",
             "commune" => ["ixelles", "uccle", "forest", "city-of-brussels"]
           }

    assert LazyHTML.attribute(beyond[~s(a[rel="next"])], "href") == []
  end

  test "the mandate pager preserves language, search, and commune selection" do
    import Phoenix.LiveViewTest

    pager =
      render_component(&BrusselsWtfWeb.TimelinePage.mandates_pager/1,
        page: 2,
        more?: true,
        locale: "en",
        selected: ["ixelles", "forest"],
        q: "dupont",
        path: "/mandates"
      )
      |> LazyHTML.from_document()

    for {side, page} <- [{"prev", nil}, {"next", 3}] do
      href = LazyHTML.attribute(pager[~s(a[rel="#{side}"])], "href") |> List.first()
      assert href
      params = URI.parse(href) |> Map.fetch!(:query) |> Plug.Conn.Query.decode()

      assert params ==
               %{
                 "lang" => "en",
                 "communes_submitted" => "1",
                 "commune" => ["ixelles", "forest"],
                 "q" => "dupont"
               }
               |> then(&if(page, do: Map.put(&1, "page", "#{page}"), else: &1))
    end

    french =
      render_component(&BrusselsWtfWeb.TimelinePage.mandates_pager/1,
        page: 1,
        more?: true,
        locale: "fr",
        selected: ["ixelles"],
        q: "",
        path: "/mandates"
      )
      |> LazyHTML.from_document()

    assert LazyHTML.text(french[~s(a[rel="next"])]) == "Page suivante"

    assert LazyHTML.attribute(french[~s(a[rel="prev"])], "href") == []

    last =
      render_component(&BrusselsWtfWeb.TimelinePage.mandates_pager/1,
        page: 3,
        more?: false,
        locale: "nl",
        selected: [],
        q: "",
        path: "/mandates"
      )
      |> LazyHTML.from_document()

    assert LazyHTML.attribute(last[~s(a[rel="next"])], "href") == []
    assert LazyHTML.text(last[~s(a[rel="prev"])]) == "Vorige pagina"
    prev_href = LazyHTML.attribute(last[~s(a[rel="prev"])], "href") |> List.first()
    params = URI.parse(prev_href) |> Map.fetch!(:query) |> Plug.Conn.Query.decode()

    assert params == %{"lang" => "nl", "communes_submitted" => "1", "page" => "2"}
  end

  test "installation period never invents a term end but can display an explicit end" do
    import Phoenix.LiveViewTest

    for {locale, ending} <- [
          {"en", "end date: 2025-02-03"},
          {"fr", "date de fin : 2025-02-03"},
          {"nl", "einddatum: 2025-02-03"}
        ] do
      html =
        render_component(&BrusselsWtfWeb.PublicMandate.installation_period/1,
          locale: locale,
          relationship: %{effective_from: ~D[2024-12-01], effective_to: ~D[2025-02-03]}
        )

      assert html =~ ending
    end
  end
end
