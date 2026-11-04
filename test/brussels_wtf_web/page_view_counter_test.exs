defmodule BrusselsWtfWeb.PageViewCounterTest do
  # Not async: the buffer is a single named process that every request reaches.
  use BrusselsWtfWeb.ConnCase, async: false

  alias BrusselsWtf.Readership
  alias BrusselsWtf.Readership.PageViewBuffer

  @reviewer %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}
  @browser "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36"

  defp visit(conn, path, headers \\ []) do
    [{"user-agent", @browser} | headers]
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> get(path)
  end

  defp counts do
    :ok = PageViewBuffer.flush()

    Readership.list_page_view_counts_since!(~D[2000-01-01], actor: @reviewer)
    |> Enum.map(&{&1.route_pattern, &1.locale, &1.referrer_host, &1.count})
    |> Enum.sort()
  end

  describe "with the buffer running" do
    setup do
      start_supervised!({PageViewBuffer, flush_interval: :infinity})
      :ok
    end

    test "daily totals group by route pattern, locale and referrer host", %{conn: conn} do
      visit(conn, "/about?lang=en")
      visit(conn, "/about?lang=en")
      visit(conn, "/about?lang=fr", [{"referer", "https://www.Example.org/some/private?page=1"}])

      assert counts() == [
               {"/about", "en", "direct", 2},
               {"/about", "fr", "example.org", 1}
             ]

      visit(conn, "/about?lang=en")
      assert {"/about", "en", "direct", 3} in counts()
    end

    test "a dynamic route stores its pattern, never the requested identifier", %{conn: conn} do
      fixture = BrusselsWtf.Test.PublicProfileFixture.load!()

      %{person: person} =
        BrusselsWtf.Test.PublicProfileFixture.publish_person!(fixture, "Alex Public", 42)

      visit(conn, "/people/#{person.id}?lang=en")

      assert counts() == [{"/people/:id", "en", "direct", 1}]
    end

    test "every public page counts under its route pattern", %{conn: conn} do
      for path <- ~w(/ /about /coverage /coverage/coming-up /coverage/awaiting-outcome
                     /coverage/decisions /coverage/contested-votes /mandates) do
        assert visit(conn, path <> "?lang=en").status == 200
      end

      assert counts() |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               ~w(/ /about /coverage /coverage/awaiting-outcome /coverage/coming-up
                  /coverage/contested-votes /coverage/decisions /mandates)
    end

    test "only successful public pages count", %{conn: conn} do
      visit(conn, "/meetings/ixelles/does-not-exist?lang=en")
      visit(conn, "/citizen/sign-in?lang=en")
      visit(conn, "/review/login?lang=en")
      visit(conn, "/sitemap.xml")
      visit(conn, "/health/live")
      visit(conn, "/review?lang=en")

      assert counts() == []
    end

    test "obvious bots, tools, prefetches and missing user agents are excluded", %{conn: conn} do
      for agent <- [
            "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
            "Mozilla/5.0 AppleWebKit/537.36 (compatible; bingbot/2.0)",
            "facebookexternalhit/1.1",
            "curl/8.5.0",
            "python-requests/2.32",
            "Mozilla/5.0 HeadlessChrome/130.0.0.0 Safari/537.36",
            "GPTBot/1.1"
          ] do
        conn |> recycle() |> put_req_header("user-agent", agent) |> get("/about?lang=en")
      end

      conn |> recycle() |> get("/about?lang=en")
      visit(conn, "/about?lang=en", [{"sec-purpose", "prefetch"}])
      visit(conn, "/about?lang=en", [{"purpose", "prefetch"}])

      assert counts() == []
    end

    test "unusable and same-site referrers fall back to direct", %{conn: conn} do
      for referrer <- [
            "not a url",
            "android-app://com.example.app/",
            "http://192.0.2.7/private",
            "http://[2001:db8::1]/",
            "http://localhost/",
            "https://user:secret@/",
            <<"https://", 0xFF, 0xFE, ".example/">>,
            "https://" <> String.duplicate("a", 300) <> ".example/",
            "http://localhost:4002/coverage",
            "http://www.example.com/same-site-under-test-host"
          ] do
        assert visit(conn, "/about?lang=en", [{"referer", referrer}]).status == 200
      end

      assert counts() == [{"/about", "en", "direct", 10}]
    end

    test "referrer credentials and ports are dropped", %{conn: conn} do
      visit(conn, "/about?lang=en", [{"referer", "https://user:secret@news.example:8443/a?b=c"}])
      assert counts() == [{"/about", "en", "news.example", 1}]
    end

    test "no IP, user agent, cookie, path or query is stored", %{conn: conn} do
      conn
      |> Map.put(:remote_ip, {198, 51, 100, 23})
      |> put_req_cookie("brussels_wtf_locale", "fr")
      |> visit("/about?lang=en&marker=query-secret", [
        {"user-agent", "Mozilla/5.0 Firefox/131.0 ua-secret"},
        {"referer", "https://news.example/path-secret?q=referrer-secret"},
        {"x-forwarded-for", "203.0.113.9"}
      ])

      assert length(counts()) == 1

      %{columns: columns} =
        BrusselsWtf.Repo.query!(
          "SELECT column_name FROM information_schema.columns WHERE table_name = 'page_view_daily_counts'"
        )
        |> then(&%{columns: List.flatten(&1.rows)})

      # No id either: a time-ordered id would reveal when a bucket's first visit was written.
      assert Enum.sort(columns) == ~w(count day locale referrer_host route_pattern)

      %{rows: rows} =
        BrusselsWtf.Repo.query!(
          "SELECT row_to_json(page_view_daily_counts)::text FROM page_view_daily_counts"
        )

      stored = inspect(rows)

      for secret <-
            ~w(198.51.100.23 203.0.113.9 ua-secret Firefox query-secret path-secret referrer-secret) do
        refute stored =~ secret
      end
    end

    test "referrer spam folds into one bucket past the daily cap", %{conn: conn} do
      cap = Readership.referrer_hosts_per_day()
      day = BrusselsWtfWeb.MeetingTime.today()

      for number <- 1..cap do
        :ok =
          Readership.record_page_views({day, "/about", "en", "spam#{number}.example"}, 1)
      end

      for number <- 1..3 do
        visit(conn, "/about?lang=en", [{"referer", "https://new#{number}.example/"}])
      end

      rows = counts()
      assert length(rows) == cap + 1
      assert {"/about", "en", "other", 3} in rows
      assert {"/about", "en", "spam1.example", 1} in rows

      # A host that was already counted that day keeps its own row.
      visit(conn, "/about?lang=en", [{"referer", "https://spam1.example/"}])
      assert {"/about", "en", "spam1.example", 2} in counts()
    end

    test "the visit is attributed to the Brussels calendar day", %{conn: conn} do
      BrusselsWtf.Clock.Controlled.set(~U[2026-06-30 22:30:00Z])
      visit(conn, "/about?lang=en")
      :ok = PageViewBuffer.flush()

      assert [%{day: ~D[2026-07-01]}] =
               Readership.list_page_view_counts_since!(~D[2000-01-01], actor: @reviewer)
    end
  end

  describe "failure isolation" do
    test "pages render when the buffer is not running", %{conn: conn} do
      refute Process.whereis(PageViewBuffer)
      assert visit(conn, "/about?lang=en").status == 200
    end

    test "a failing write leaves the page and buffer healthy, and retains the count", %{
      conn: conn
    } do
      parent = self()
      {:ok, mode} = Agent.start_link(fn -> :raise end)

      write = fn key, count ->
        case Agent.get(mode, & &1) do
          :raise -> raise "database unavailable"
          :throw -> throw(:database_unavailable)
          :exit -> exit(:database_unavailable)
          :error -> {:error, :database_unavailable}
          :ok -> send(parent, {:written, key, count}) && :ok
        end
      end

      start_supervised!({PageViewBuffer, flush_interval: :infinity, write: write})
      assert visit(conn, "/about?lang=en").status == 200

      for failure <- [:raise, :throw, :exit, :error] do
        Agent.update(mode, fn _ -> failure end)
        assert {:error, _} = PageViewBuffer.flush()
        assert visit(conn, "/about?lang=en").status == 200
      end

      Agent.update(mode, fn _ -> :ok end)
      assert :ok = PageViewBuffer.flush()
      assert_received {:written, {_day, "/about", "en", "direct"}, 5}

      assert :ok = PageViewBuffer.flush()
      refute_received {:written, _, _}
    end

    test "pending counts are bounded while writes fail", %{conn: conn} do
      start_supervised!(
        {PageViewBuffer,
         flush_interval: :infinity, max_pending: 2, write: fn _, _ -> {:error, :down} end}
      )

      for referrer <- ~w(a b c d) do
        visit(conn, "/about?lang=en", [{"referer", "https://#{referrer}.example/"}])
      end

      assert PageViewBuffer.pending_size() == 2
    end

    test "buffered counts are written when the buffer shuts down", %{conn: conn} do
      start_supervised!({PageViewBuffer, flush_interval: :infinity})
      visit(conn, "/about?lang=en")
      :sys.get_state(PageViewBuffer)
      :ok = stop_supervised(PageViewBuffer)

      assert [%{count: 1}] =
               Readership.list_page_view_counts_since!(~D[2000-01-01], actor: @reviewer)
    end

    test "counts are flushed on the periodic timer", %{conn: conn} do
      start_supervised!({PageViewBuffer, flush_interval: 10})
      visit(conn, "/about?lang=en")

      assert eventually(fn ->
               Readership.list_page_view_counts_since!(~D[2000-01-01], actor: @reviewer) != []
             end)
    end
  end

  test "the page view counts cannot be read without a reviewer actor" do
    assert {:error, %Ash.Error.Forbidden{}} =
             Readership.list_page_view_counts_since(~D[2000-01-01])
  end

  describe "reader totals in the review area" do
    setup %{conn: conn} do
      start_supervised!({PageViewBuffer, flush_interval: :infinity})
      {:ok, conn: conn}
    end

    test "an anonymous visitor is sent to the review login", %{conn: conn} do
      assert redirected_to(get(conn, "/review/readership")) == "/review/login"
    end

    test "a reviewer sees totals by day, route, locale and referrer, without any form", %{
      conn: conn
    } do
      BrusselsWtf.Clock.Controlled.set(~U[2026-07-01 10:00:00Z])
      visit(conn, "/about?lang=en", [{"referer", "https://news.example/"}])
      visit(conn, "/about?lang=fr")
      visit(conn, "/coverage?lang=fr")
      :ok = PageViewBuffer.flush()

      html =
        conn
        |> init_test_session(%{})
        |> BrusselsWtfWeb.ReviewAuth.log_in(@reviewer)
        |> get("/review/readership")
        |> html_response(200)

      document = LazyHTML.from_document(html)

      row = fn id, label ->
        document["##{id} tbody tr"]
        |> Enum.map(&LazyHTML.text/1)
        |> Enum.map(&String.split/1)
        |> Enum.find(&(hd(&1) == label))
      end

      assert row.("by-day", "2026-07-01") == ["2026-07-01", "3"]
      assert row.("by-route", "/about") == ["/about", "2"]
      assert row.("by-locale", "fr") == ["fr", "2"]
      assert row.("by-referrer", "news.example") == ["news.example", "1"]
      assert Enum.empty?(document["main form"])
    end

    test "days older than the window are left out", %{conn: conn} do
      BrusselsWtf.Clock.Controlled.set(~U[2026-05-01 10:00:00Z])
      visit(conn, "/about?lang=en")
      :ok = PageViewBuffer.flush()
      BrusselsWtf.Clock.Controlled.set(~U[2026-07-01 10:00:00Z])

      html =
        conn
        |> init_test_session(%{})
        |> BrusselsWtfWeb.ReviewAuth.log_in(@reviewer)
        |> get("/review/readership")
        |> html_response(200)

      refute html =~ "2026-05-01"
    end
  end

  defp eventually(check, attempts \\ 100) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(check, attempts - 1)
    end
  end
end
