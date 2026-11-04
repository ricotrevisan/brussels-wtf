# Reader counts and search indexing

## Reader counts

Successful public `GET` page views are counted as daily totals by route pattern, locale and referrer host in `page_view_daily_counts`. No IP address, user agent, cookie, path value, query string or time finer than the Brussels calendar day is stored, and no third party is involved. Obvious bots, tools and prefetches are excluded; a browser-like automated client can still be counted.

Requests only hand a count to an in-memory buffer, which writes every 30 seconds. A failed write is retried and never affects the page. A crash or hard stop can lose at most the unwritten interval.

Read the totals at `/review/readership` (review login, last 30 days).

## Sitemap

`/sitemap.xml` lists each public page once per language, using the same gates as the pages. Withdrawn, draft, retired and private routes stay out. Pages that render only a withdrawal notice or no public entries send `noindex`.

The app keeps a built sitemap for 5 minutes and responses may be cached for 5 more, so a withdrawn page can stay listed for up to 10 minutes. Its page sends `noindex` immediately. If a build fails, the route returns `503` rather than an older sitemap.

Check it after a deploy:

```bash
curl -fsS https://brussels.wtf/sitemap.xml -o /tmp/sitemap.xml
xmllint --noout /tmp/sitemap.xml
grep -c '<loc>' /tmp/sitemap.xml
curl -fsS https://brussels.wtf/robots.txt | grep Sitemap
```

Check that the counter moves. `curl` is treated as a bot, so a browser user agent is required:

```bash
curl -fsS -o /dev/null -A 'Mozilla/5.0 (X11; Linux x86_64) Firefox/131.0' 'https://brussels.wtf/about?lang=en'
```

After 30 seconds, `/review/readership` shows the `/about` total increased.

Or read today's totals from the running release (read-only):

```bash
/app/bin/brussels_wtf rpc 'BrusselsWtf.Readership.list_page_view_counts_since!(BrusselsWtfWeb.MeetingTime.today(), authorize?: false) |> Enum.map(&{&1.route_pattern, &1.locale, &1.referrer_host, &1.count}) |> IO.inspect()'
```

## Search Console (needs Rico's Google account)

1. Open <https://search.google.com/search-console> and add the **Domain** property `brussels.wtf`.
2. Copy the `google-site-verification=…` TXT value Google shows and add it to the `brussels.wtf` DNS zone.
3. Press **Verify**. If it fails, wait for DNS to propagate and retry.
4. Open **Sitemaps**, submit `https://brussels.wtf/sitemap.xml`, and confirm the status is **Success**.
5. A few days later, open **Pages** and check that the language URLs (`?lang=fr`, `nl`, `en`) are being indexed.
