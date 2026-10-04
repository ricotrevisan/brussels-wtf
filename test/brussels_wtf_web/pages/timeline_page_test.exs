defmodule BrusselsWtfWeb.TimelinePageTest do
  use BrusselsWtfWeb.ConnCase, async: false

  alias BrusselsWtf.Council

  test "homepage leads with commune choice and bounded categories, not search or a names wall", %{
    conn: conn
  } do
    document = conn |> get("/?lang=en") |> html_response(200) |> LazyHTML.from_document()
    assert Enum.count(document["h1"]) == 1
    assert Enum.count(document[~s(form[method="get"][action="/"][data-reader-communes])]) == 1
    assert Enum.count(document[~s(input[name="commune[]"]:checked)]) == 4
    assert Enum.count(document[~s(input[name="q"])]) == 0
    assert Enum.count(document["#verified-mandates"]) == 0

    for path <- ~w(/coverage/coming-up /coverage/awaiting-outcome /coverage/decisions /mandates) do
      assert Enum.any?(
               LazyHTML.attribute(document["a"], "href"),
               &String.starts_with?(&1, path <> "?")
             )
    end
  end

  test "each preview is capped after commune filtering while categories retain all searchable content",
       %{conn: conn} do
    for {slug, offset} <- [{"ixelles", 10}, {"forest", 0}],
        {category, state, days} <- [
          {"coming-up", :proposal, 30},
          {"awaiting-outcome", :proposal, -30},
          {"decisions", :decision, -60}
        ] do
      seed_category!(slug, category, state, days + offset)
    end

    projection =
      Council.list_public_timeline!(
        communes: ["forest"],
        locale: "en",
        commune_names: %{"forest" => "Forest"},
        limit: 5
      )

    for group <- [:coming, :awaiting, :decided] do
      assert length(projection[group]) == 5
      assert Enum.all?(projection[group], &(&1.page.council_meeting.commune.slug == "forest"))
    end

    searched =
      Council.list_public_timeline!(
        communes: ["forest"],
        locale: "en",
        commune_names: %{"forest" => "Forest"},
        search: "needle-6",
        groups: [:coming],
        limit: 5
      )

    assert length(searched.coming) == 1

    home = conn |> get("/?lang=en") |> html_response(200) |> LazyHTML.from_document()

    for id <- ~w(coming-up awaiting-outcome previously) do
      assert Enum.count(home[~s(section[aria-labelledby="#{id}"] article)]) == 5
    end

    selected = "lang=en&communes_submitted=1&commune[]=forest"

    home =
      conn |> recycle() |> get("/?#{selected}") |> html_response(200) |> LazyHTML.from_document()

    assert Enum.count(home["article"]) == 15
    assert Enum.uniq(LazyHTML.attribute(home["article"], "data-commune")) == ["forest"]

    for category <- ~w(coming-up awaiting-outcome decisions) do
      path = "/coverage/#{category}"

      page =
        conn
        |> recycle()
        |> get("#{path}?#{selected}")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert Enum.count(page["article"]) >= 7
      assert Enum.count(page["article"] |> Enum.filter(&(LazyHTML.text(&1) =~ "needle-"))) == 7
      assert Enum.count(page[~s(form[method="get"][action="#{path}"])]) == 1
      assert Enum.count(page[~s(input[name="q"])]) == 1
      assert Enum.count(page[~s(button[data-follow-control])]) == 4
      assert LazyHTML.attribute(page[~s(link[rel="canonical"])], "href") == [path]

      filtered =
        conn
        |> recycle()
        |> get("#{path}?#{selected}&q=needle-6")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert Enum.count(filtered["article"]) == 1
      assert LazyHTML.text(filtered["article"]) =~ "needle-6"
      item_href = LazyHTML.attribute(filtered["article a"], "href") |> List.first()
      assert Plug.Conn.Query.decode(URI.parse(item_href).query)["commune"] == ["forest"]
      assert URI.parse(item_href).fragment == "item-6"
      reset = LazyHTML.attribute(filtered["a[data-reader-reset]"], "href") |> List.first()
      refute reset =~ "q="
      assert Plug.Conn.Query.decode(URI.parse(reset).query)["commune"] == ["forest"]

      reset_page =
        conn |> recycle() |> get(reset) |> html_response(200) |> LazyHTML.from_document()

      assert Enum.count(reset_page["article"]) >= 7

      for href <- LazyHTML.attribute(filtered["a[hreflang]"], "href") do
        assert href =~ "q=needle-6"
        assert Plug.Conn.Query.decode(URI.parse(href).query)["commune"] == ["forest"]
      end
    end

    empty =
      conn
      |> recycle()
      |> get("/coverage/coming-up?lang=en&communes_submitted=1")
      |> html_response(200)

    refute empty =~ "needle-"
    assert empty =~ "No upcoming coverage"
    assert conn |> recycle() |> get("/coverage/not-a-category") |> response(404)
  end

  test "trailing-slash result routes render the same category and preserve query context", %{
    conn: conn
  } do
    query = "lang=nl&q=budget&communes_submitted=1&commune[]=forest"

    for path <- ~w(/coverage/coming-up /coverage/awaiting-outcome /coverage/decisions /mandates) do
      canonical =
        conn
        |> recycle()
        |> get("#{path}?#{query}")
        |> html_response(200)
        |> LazyHTML.from_document()

      trailing =
        conn
        |> recycle()
        |> get("#{path}/?#{query}")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert LazyHTML.text(trailing["h1"]) == LazyHTML.text(canonical["h1"])

      assert LazyHTML.attribute(trailing["section"], "aria-labelledby") ==
               LazyHTML.attribute(canonical["section"], "aria-labelledby")

      assert LazyHTML.attribute(trailing[~s(link[rel="canonical"])], "href") == [path]
      assert Enum.count(trailing[~s(form[method="get"][action="#{path}"])]) == 1
      assert LazyHTML.attribute(trailing[~s(input[name="q"])], "value") == ["budget"]

      assert LazyHTML.attribute(trailing[~s(input[name="commune[]"]:checked)], "value") == [
               "forest"
             ]

      for href <- LazyHTML.attribute(trailing["a[hreflang]"], "href") do
        assert URI.parse(href).path == path
        params = Plug.Conn.Query.decode(URI.parse(href).query)
        assert params["q"] == "budget"
        assert params["commune"] == ["forest"]
        assert params["communes_submitted"] == "1"
      end
    end
  end

  test "structured search parameters keep searchable routes usable", %{conn: conn} do
    for path <- ~w(/coverage/coming-up /coverage/awaiting-outcome /coverage/decisions /mandates),
        query <- ["q[]=budget", "q[field]=budget"] do
      document =
        conn
        |> recycle()
        |> get("#{path}?lang=en&#{query}")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert LazyHTML.attribute(document[~s(input[name="q"])], "value") == [""]
    end
  end

  defp seed_category!(slug, category, state, days) do
    commune =
      BrusselsWtf.Ingestion.create_commune!(%{
        slug: slug,
        name: BrusselsWtf.Communes.configuration!(slug).name,
        index_url: "https://example.invalid/#{slug}"
      })

    meeting =
      Council.upsert_meeting!(%{
        commune_id: commune.id,
        municipal_identifier: "preview-#{category}",
        scheduled_on: Date.add(BrusselsWtfWeb.MeetingTime.today(), days)
      })

    page =
      Council.upsert_meeting_page!(%{
        council_meeting_id: meeting.id,
        citation_url: "https://example.invalid/#{slug}",
        procedural_state: state
      })

    for number <- 1..7 do
      item =
        Council.upsert_rendered_agenda_item!(%{
          council_meeting_id: meeting.id,
          item_number: "#{number}",
          stable_anchor: "item-#{number}",
          source_wording: "Synthetic preview fixture",
          procedural_state: state
        })

      Council.upsert_proposal!(%{
        agenda_item_id: item.id,
        text: "Synthetic preview fixture",
        status: :proposed,
        render_key: "preview-test"
      })

      if state == :decision do
        decision =
          Council.upsert_decision!(%{
            agenda_item_id: item.id,
            render_key: "preview-test",
            disposition: :approved,
            statement: "Synthetic decision fixture"
          })

        Council.mark_agenda_item_decided!(item, %{
          current_decision_id: decision.id,
          outcome: :approved
        })
      end

      for locale <- ~w(fr nl en) do
        Council.upsert_coverage_variant!(%{
          agenda_item_id: item.id,
          locale: locale,
          title: "#{slug} #{category} needle-#{number}",
          summary: "Synthetic preview fixture",
          proposal_summary: "Synthetic preview fixture",
          decision_summary: if(state == :decision, do: "Synthetic decision fixture"),
          provenance: []
        })
      end
    end

    BrusselsWtf.Seeds.PublicTimeline.publish_for_seed!(page)
  end
end
