defmodule BrusselsWtfWeb.PublicMetadataTest do
  use BrusselsWtfWeb.ConnCase, async: false

  alias BrusselsWtf.{Council, Ingestion}
  alias BrusselsWtf.Test.Harness

  @host "http://localhost:4002"
  @static ~w(/ /about /coverage /coverage/coming-up /coverage/awaiting-outcome /coverage/decisions /coverage/contested-votes /mandates)

  defp page(conn, path_and_query) do
    conn |> recycle() |> get(path_and_query) |> html_response(200) |> LazyHTML.from_document()
  end

  defp description(document) do
    [value] = LazyHTML.attribute(document[~s(meta[name="description"])], "content")
    value
  end

  test "static public pages have an absolute canonical and a distinct description per language",
       %{conn: conn} do
    for path <- @static do
      descriptions =
        for locale <- ~w(fr nl en) do
          document = page(conn, "#{path}?lang=#{locale}")

          assert LazyHTML.attribute(document[~s(link[rel="canonical"])], "href") == [
                   "#{@host}#{path}?lang=#{locale}"
                 ]

          assert LazyHTML.attribute(document[~s(link[hreflang="x-default"])], "href") == [
                   "#{@host}#{path}"
                 ]

          text = description(document)
          assert String.length(text) in 40..160
          text
        end

      assert length(Enum.uniq(descriptions)) == 3
    end
  end

  test "the canonical ignores filter parameters and normalizes the language tag", %{conn: conn} do
    document = page(conn, "/coverage/decisions?lang=nl-BE&q=budget&commune[]=forest")

    assert LazyHTML.attribute(document[~s(link[rel="canonical"])], "href") == [
             "#{@host}/coverage/decisions?lang=nl"
           ]
  end

  test "a request Host header cannot change the canonical origin", %{conn: conn} do
    document =
      conn
      |> Map.put(:host, "attacker.example")
      |> get("/about?lang=en")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert LazyHTML.attribute(document[~s(link[rel="canonical"])], "href") == [
             "#{@host}/about?lang=en"
           ]
  end

  test "a meeting description is localized and states no outcome", %{conn: conn} do
    Harness.load("ixelles/final-267")
    :ok = Ingestion.poll_now("ixelles")
    :ok = Harness.drain_pipeline()
    {:ok, meeting_page} = Council.get_published_meeting_page("ixelles", "267")
    date = Date.to_iso8601(meeting_page.council_meeting.scheduled_on)

    assert description(page(conn, "/meetings/ixelles/267?lang=nl")) =~ "Elsene"
    assert description(page(conn, "/meetings/ixelles/267?lang=fr")) =~ "Ixelles"

    english = description(page(conn, "/meetings/ixelles/267?lang=en"))
    assert english =~ date
    refute english =~ ~r/adopted|approved|rejected/i
  end

  test "a long name cannot push a description over the limit" do
    name = "Alex " <> String.duplicate("Verylongname ", 20) <> "Public"

    for locale <- ~w(fr nl en),
        text <- [
          BrusselsWtfWeb.PublicDescription.person(locale, name),
          BrusselsWtfWeb.PublicDescription.company(locale, name),
          BrusselsWtfWeb.PublicDescription.dossier(locale, name)
        ] do
      assert String.length(text) <= 160
      assert text =~ "Alex"
    end
  end

  test "private pages carry no canonical link", %{conn: conn} do
    document = page(conn, "/citizen/sign-in")
    assert Enum.empty?(document[~s(link[rel="canonical"])])
  end

  test "the about page discloses the first-party count in each language", %{conn: conn} do
    assert LazyHTML.text(page(conn, "/about?lang=en")["main"]) =~ "no third-party service"
    assert LazyHTML.text(page(conn, "/about?lang=fr")["main"]) =~ "aucun service tiers"
    assert LazyHTML.text(page(conn, "/about?lang=nl")["main"]) =~ "geen externe dienst"
  end
end
