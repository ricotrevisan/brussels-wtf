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
    before = conn |> get("/?lang=en") |> html_response(200)
    refute before =~ "Installation documented"
    refute before =~ "Léa Exemple"

    assert {:ok, reports} =
             MunicipalInstallation.publish(@slugs, actor: actor, max_facts_per_commune: 2)

    assert Enum.all?(reports, &(&1.published_new == 2))
    roles = Identity.list_public_relationships!()
    assert length(roles) == 8

    for {locale, {history, wording}} <- @copy do
      homepage = conn |> recycle() |> get("/?lang=#{locale}") |> html_response(200)
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
        |> get("/?lang=en&communes_submitted=1&commune[]=#{slug}")
        |> html_response(200)

      home = LazyHTML.from_document(html)
      links = LazyHTML.attribute(home["#verified-mandates + ul a"], "href")

      for role <- roles do
        link = "/people/#{role.subject_id}?lang=en#fact-#{role.fact_id}"
        assert link in links == (role.object_name == name)
      end
    end

    empty = conn |> recycle() |> get("/?lang=en&communes_submitted=1") |> html_response(200)
    refute empty =~ ~s(id="verified-mandates")
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
