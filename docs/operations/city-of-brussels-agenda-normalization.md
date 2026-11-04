# City of Brussels agenda normalization (issue #150)

New City agendas, supplements and addenda normalize and publish without an operator. This retry is
a one-off for the documents that arrived before the normalizer shipped. Layout findings:
`docs/research/2026-11-04-city-of-brussels-agenda-layouts.md`.

## Retry stale agendas

Run after the release is live. Put the script path in `S` first:

```bash
ssh hetzner
C=$(docker ps --format '{{.Names}}' | grep '^sn1f08alzbb5reus2ynxrswz-' | head -1)
S='path = Application.app_dir(:brussels_wtf, "priv/ops/retry_city_of_brussels_agendas_20261104.exs")'

# 1. Dry run. Changes nothing.
docker exec "$C" /app/bin/brussels_wtf rpc "$S; Code.eval_file(path)"
```

Check that `normalizer_loaded` is `true`, `coverage_mode` is `:paid`, and `month_budget` leaves room
under `monthly_budget_cents`. Expect four ready candidates, in this order:

| Meeting | Document | Items | Proposals |
| --- | --- | --- | --- |
| 2026-10-12 | agenda | 55 | 28 |
| 2026-10-12 | supplement | 36 | 24 |
| 2026-09-21 | agenda | 34 | 24 |
| 2026-09-21 | supplement | 28 | 14 |

The 2026-09-07 supplement must show `{:skip, :recorded_corpus_meeting}`. Stop if the list differs.

```bash
# 2. Retry one document. Use the reviewer id you use in the review inbox.
docker exec "$C" /app/bin/brussels_wtf rpc "$S; Code.eval_string(File.read!(path), apply?: true, limit: 1, actor_id: \"<reviewer id>\")"
```

Wait until `/meetings/city-of-brussels/2026-10-12` is live with `?lang=fr`, `?lang=nl` and `?lang=en`,
then repeat step 2 for the supplement. Check again, then repeat for 2026-09-21 if the budget allows.
Each document regenerates its page once, because a supplement adds points. Uccle's 34 publishable
items charged 26 cents, so expect well under 200 cents for all four. The reservation refuses any
call over the monthly limit.

A retry never covers more than 25 runs. A candidate with an unclean preview, or another open
normalization case on its source, is reported and never retried. An ambiguity opens a review case:
read it in the review inbox.

## Check the recorded pages did not move

Compare with the values in the PR. Status, input hash, current revision and revision count must match.

```bash
docker exec "$C" /app/bin/brussels_wtf rpc 'for id <- ~w(2026-06-08 2026-06-29 2026-09-07) do %{rows: [r]} = BrusselsWtf.Repo.query!("select p.publication_status::text, p.publication_input_hash, p.current_revision_id::text, (select count(*) from publication_revisions r where r.meeting_page_id = p.id) from meeting_pages p join council_meetings m on m.id = p.council_meeting_id join communes c on c.id = m.commune_id where c.slug = $1 and m.municipal_identifier = $2", ["city-of-brussels", id]); IO.inspect([id | r]) end'
```
