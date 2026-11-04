defmodule BrusselsWtfWeb.PublicSitemapTest do
  use BrusselsWtfWeb.ConnCase, async: false

  require Record

  alias BrusselsWtf.{Council, Identity, Ingestion, Review}
  alias BrusselsWtf.Test.{Harness, PublicProfileFixture}

  Record.defrecord(
    :xml_element,
    :xmlElement,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecord(
    :xml_text,
    :xmlText,
    Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecord(
    :xml_attribute,
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  @host "http://localhost:4002"
  @reviewer %Review.Actor{id: "rico", role: :reviewer}
  @withdrawal_reasons %{
    "fr" => "Retiré pour vérification.",
    "nl" => "Ingetrokken voor controle.",
    "en" => "Withdrawn for checking."
  }

  defp entries(conn) do
    body = conn |> recycle() |> get("/sitemap.xml") |> response(200)
    {document, _rest} = body |> String.to_charlist() |> :xmerl_scan.string(quiet: true)

    for url <- :xmerl_xpath.string(~c"/urlset/url", document) do
      [loc] = :xmerl_xpath.string(~c"loc/text()", url)

      alternates =
        for link <- :xmerl_xpath.string(~c"*", url),
            xml_element(link, :name) == :"xhtml:link",
            into: %{} do
          [hreflang] = :xmerl_xpath.string(~c"@hreflang", link)
          [href] = :xmerl_xpath.string(~c"@href", link)
          {attribute_value(hreflang), attribute_value(href)}
        end

      {to_string(xml_text(loc, :value)), alternates}
    end
  end

  defp attribute_value(attribute), do: to_string(xml_attribute(attribute, :value))
  defp locs(conn), do: conn |> entries() |> Enum.map(&elem(&1, 0))

  defp publish_ixelles_meeting! do
    Harness.load("ixelles/final-267")
    :ok = Ingestion.poll_now("ixelles")
    :ok = Harness.drain_pipeline()
    {:ok, page} = Council.get_published_meeting_page("ixelles", "267")
    page
  end

  test "lists each public page in all three languages with absolute hreflang alternates", %{
    conn: conn
  } do
    publish_ixelles_meeting!()

    entries = entries(conn)
    locs = Enum.map(entries, &elem(&1, 0))

    for path <- [
          "/",
          "/about",
          "/coverage",
          "/coverage/coming-up",
          "/coverage/awaiting-outcome",
          "/coverage/decisions",
          "/coverage/contested-votes",
          "/mandates",
          "/meetings/ixelles/267"
        ],
        locale <- ~w(fr nl en) do
      assert "#{@host}#{path}?lang=#{locale}" in locs
    end

    {_loc, alternates} =
      Enum.find(entries, fn {loc, _} -> loc == "#{@host}/meetings/ixelles/267?lang=nl" end)

    assert alternates == %{
             "fr" => "#{@host}/meetings/ixelles/267?lang=fr",
             "nl" => "#{@host}/meetings/ixelles/267?lang=nl",
             "en" => "#{@host}/meetings/ixelles/267?lang=en",
             "x-default" => "#{@host}/meetings/ixelles/267"
           }
  end

  test "is cookie-free XML that any cache may hold only briefly", %{conn: conn} do
    response = get(conn, "/sitemap.xml")

    assert ["application/xml" <> _] = get_resp_header(response, "content-type")
    assert get_resp_header(response, "set-cookie") == []
    assert get_resp_header(response, "cache-control") == ["public, max-age=300"]
  end

  test "a page's canonical and hreflang links match its sitemap entry", %{conn: conn} do
    publish_ixelles_meeting!()

    for {loc, alternates} <- entries(conn),
        String.contains?(loc, "/meetings/ixelles/267") do
      document =
        conn |> recycle() |> get(loc) |> html_response(200) |> LazyHTML.from_document()

      assert LazyHTML.attribute(document[~s(link[rel="canonical"])], "href") == [loc]

      for {hreflang, href} <- alternates do
        assert LazyHTML.attribute(
                 document[~s(link[rel="alternate"][hreflang="#{hreflang}"])],
                 "href"
               ) == [href]
      end
    end
  end

  test "a withdrawn meeting leaves the sitemap and tells crawlers not to index its notice", %{
    conn: conn
  } do
    page = publish_ixelles_meeting!()
    assert "#{@host}/meetings/ixelles/267?lang=fr" in locs(conn)

    Council.PublicationLifecycle.withdraw!(page.id, @withdrawal_reasons, @reviewer)

    refute Enum.any?(locs(conn), &String.contains?(&1, "/meetings/ixelles/267"))

    document =
      conn
      |> recycle()
      |> get("/meetings/ixelles/267?lang=en")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert LazyHTML.attribute(document[~s(meta[name="robots"])], "content") == ["noindex"]
    assert Enum.empty?(document[~s(link[rel="canonical"])])
  end

  test "a meeting that has never been published stays out", %{conn: conn} do
    Harness.load("ixelles/final-267")
    :ok = Ingestion.poll_now("ixelles")
    :ok = Harness.drain_pipeline(until: :extract)

    refute Enum.any?(locs(conn), &String.contains?(&1, "/meetings/"))
  end

  test "only a dossier with public entries in every language appears", %{conn: conn} do
    page = publish_ixelles_meeting!()
    item = hd(page.council_meeting.agenda_items)

    public =
      Council.upsert_dossier!(%{slug: "public-dossier", title: "Public", localized_titles: %{}})

    Council.upsert_dossier_link!(%{
      agenda_item_id: item.id,
      dossier_id: public.id,
      match_method: :editorial,
      status: :active,
      disposition: :confirmed
    })

    empty =
      Council.upsert_dossier!(%{slug: "empty-dossier", title: "Empty", localized_titles: %{}})

    survivor = public

    retired =
      Council.upsert_dossier!(%{slug: "retired-dossier", title: "Old", localized_titles: %{}})

    Council.retire_dossier!(retired, %{retired_into_id: survivor.id})

    locs = locs(conn)

    for locale <- ~w(fr nl en) do
      assert "#{@host}/dossiers/public-dossier?lang=#{locale}" in locs
    end

    refute Enum.any?(locs, &String.contains?(&1, "/dossiers/empty-dossier"))
    refute Enum.any?(locs, &String.contains?(&1, "/dossiers/retired-dossier"))

    document =
      conn
      |> recycle()
      |> get("/dossiers/#{empty.slug}?lang=en")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert LazyHTML.attribute(document[~s(meta[name="robots"])], "content") == ["noindex"]
  end

  test "public profiles appear; private and merged people and private routes never do", %{
    conn: conn
  } do
    company = PublicProfileFixture.company!()
    fixture = PublicProfileFixture.load!()
    %{person: person} = PublicProfileFixture.publish_person!(fixture, "Alex Public", 42)
    %{person: merged} = PublicProfileFixture.publish_person!(fixture, "Prior Public", 43)
    Identity.merge_people!(merged.id, person.id, "note", @reviewer)

    private =
      Identity.record_person!(%{
        legal_name: "PRIVATE ONLY PERSON",
        explicit_identifier: "private-only",
        resolution_basis: :explicit_identifier,
        corroborating_facts: %{}
      })

    locs = locs(conn)

    for locale <- ~w(fr nl en) do
      assert "#{@host}/people/#{person.id}?lang=#{locale}" in locs
      assert "#{@host}/companies/#{company.enterprise_number}?lang=#{locale}" in locs
    end

    refute Enum.any?(locs, &String.contains?(&1, private.id))
    refute Enum.any?(locs, &String.contains?(&1, merged.id))

    private_prefixes = ~w(/review /citizen /feed /collections /internal /health /items /dev)

    for loc <- locs, prefix <- private_prefixes do
      refute String.starts_with?(loc, @host <> prefix)
    end
  end

  test "robots.txt points crawlers at the sitemap" do
    robots = File.read!(Application.app_dir(:brussels_wtf, "priv/static/robots.txt"))
    assert robots =~ ~r/^Sitemap: https:\/\/brussels\.wtf\/sitemap\.xml$/m
  end
end
