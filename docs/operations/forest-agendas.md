# Forest council agendas

Issue [#149](https://github.com/RicoTrevisan/brussels-wtf/issues/149). `BrusselsWtf.Processors.ForestCouncil` normalizes new Forest public agendas into cited proposals. It never emits a decision.

## Layout findings

Inspected on 4 November 2026: the accepted `native-text` artifacts retained for every Forest `agenda` and `complementary_agenda` locator from June 2026. The documents stay in the private archive.

| Meeting | Role | Pages | Points | Result |
| --- | --- | ---: | ---: | --- |
| 2026-09-01 | agenda | 9 | 47 | Layout parses; recorded-corpus meeting, refused |
| 2026-09-01 | complementary_agenda | 10 | 51 | Layout parses; recorded-corpus meeting, refused |
| 2026-09-22 | agenda | 7 | 31 | 31 proposals |
| 2026-10-13 | agenda | 8 | 34 | 32 proposals, 2 non-votable |
| 2026-06-23 | complementary_agenda | 6 | n/a | **Collège agenda of 25 June behind a council locator**, refused |

- Each page ends with a two-line footer: date, document type and page `n/M`.
- A numbered point holds a French paragraph, a blank line, then a Dutch paragraph. Section headings sit at the point number's indent. Annex counts (`3 annexes / 3 bijlagen`) follow the Dutch text.
- Either language can cross a page, and a French paragraph can end on the last line of a page. A page break therefore proves nothing on its own. The blank line separating the languages resolves it.
- A locator's date and role come from the index card, not from the document, and the Collège row shows a locator can serve the wrong document.

## Rules

- **Accepted:** Forest `agenda` and `complementary_agenda` sources for meetings from 2026-09-01. Anything else stays `processor_unimplemented`, as before.
- **Identity:** the French and Dutch commune names, both dated council headings and the public-session heading must match. Every page must carry the meeting's footer and its own page number, and the page total must match. A `huis clos` mention, a heading that disagrees with the locator role, or non-contiguous point numbers opens a review case.
- **Recorded corpus:** a meeting in the recorded corpus opens a review case. `2026-09-01` is one: its published two-point page must stay byte-identical, so its agendas are not normalized.
- **Non-votable points (ADR 0005):** points starting with `Interpellation`, `Question`, `Communication` or `Information au Conseil` keep their agenda item and carry no proposal.
- **`– Information` and `Prise d'acte` points are proposals.** Forest's minutes record a vote on these acknowledgements ([audit](../research/2026-09-11-forest-outcome-audit.md)). The proposal keeps the official wording.
- **Evidence:** the excerpt is the whole French paragraph, verified on the cited pages. A paragraph crossing a page cites both (`pages 3-4/7`) and is checked with only the running footer removed.
- **Ambiguity:** one unverifiable point fails the whole document into one review case.

Explanatory notes and motions still open a `processor_unavailable` case. It does not block publication, because those sources are not linked to the meeting.

Agenda items are keyed by point number, as in the recorded Forest corpus. In the one real pair, 2026-09-01, the complementary agenda restates all 47 base points word for word under the same numbers and adds 4. An earlier point that a later agenda drops opens a blocking review case. Known limit: a later agenda that renumbers would replace the wording under each number without a review case. Uccle's agendas do renumber, so check this if a Forest pair ever differs.

## Real-document test

CI uses minimal excerpts. To run the complete documents, export each artifact as `<output sha256>.txt` into a private directory:

```bash
FOREST_AGENDA_REAL_TEXT_DIRECTORY=/private/dir MIX_TEST_PARTITION=_w4 \
  mix test test/contracts/forest_agenda_real_test.exs --include external
```

## Post-deploy requeue

Stale `processor_unavailable` cases would block the gate once their source links to a meeting. The script uses the audited review retry, which re-extracts the retained bytes, resolves the case, normalizes, and queues automatic publication. It selects only agendas of meetings from 2026-09-01, excludes recorded-corpus meetings, previews each one, and retries only those the preview accepts, at most 25.

Open the container on `hetzner`:

```bash
ssh hetzner
c=$(docker ps --format '{{.Names}}' | grep '^sn1f08alzbb5reus2ynxrswz-' | head -1)
```

1. **Dry run.** It writes nothing.

   ```bash
   docker exec "$c" /app/bin/brussels_wtf rpc 'Code.eval_file(Application.app_dir(:brussels_wtf, "priv/ops/requeue_forest_agendas_20261104.exs"))'
   ```

   Expect `read_only: true`, `coverage_generation_mode: :paid`, `ready_count: 2`, then:
   - 2026-09-22: `items: 31, proposals: 31, non_votable: 0`
   - 2026-10-13: `items: 34, proposals: 32, non_votable: 2`
   - `recorded_corpus_meeting` for both 2026-09-01 agendas, `not_an_agenda` for notes and motions
   - `untouched_before_2026_09_01` counts the historical cases the script never retries

   Check `current_month_budget`. Stop if any of this differs.

2. **Apply.** Replace the reviewer id.

   ```bash
   docker exec "$c" /app/bin/brussels_wtf rpc 'p = Application.app_dir(:brussels_wtf, "priv/ops/requeue_forest_agendas_20261104.exs"); Code.eval_string(File.read!(p), apply?: true, limit: 2, actor_id: "<reviewer id>")'
   ```

3. **Verify.** Check `/meetings/forest/2026-10-13` and `/meetings/forest/2026-09-22` with `?lang=fr`, `?lang=nl` and `?lang=en`: every item shows an official citation. The two retried cases are resolved in `/review`.

4. **Confirm the recorded pages did not move.** The hashes must be unchanged:

   ```bash
   docker exec "$c" /app/bin/brussels_wtf rpc 'IO.inspect(BrusselsWtf.Repo.query!("select m.municipal_identifier, p.publication_input_hash, p.revision_published_at::text from meeting_pages p join council_meetings m on m.id = p.council_meeting_id join communes c on c.id = m.commune_id where c.slug = $1 order by m.scheduled_on", ["forest"]).rows, limit: :infinity)'
   ```

   | Meeting | `publication_input_hash` |
   | --- | --- |
   | 2025-04-22 | `sha256:5a653813a1fa03d16c4eabd5b5c1cdaf44ebf3f444f454cea5ac2d2884bc0104` |
   | 2026-03-24 | `sha256:d7abe72d67fc6cd682170d15e91f1c23ae8ffeac12d3c7e0756f0a8669149e7b` |
   | 2026-09-01 | `sha256:21fdf23b6ad43e22049367bca7b3f3fa054d5e09a7caa4bf14dea52b04f834b0` |

Paid generation reserves against the monthly hard limit and fails closed when it is exhausted. In November 2026, Ixelles pages of 34 to 42 items were charged 17 to 28 cents each and reserved at most 71 cents, against the 1000-cent limit, so expect about 60 cents in total for these two pages. Other generation shares that limit: read `current_month_budget` in the dry run, and leave at least 150 cents free before applying.

The two 2026-09-01 agenda cases stay open. They do not block anything, because those sources are not linked to the meeting. Closing them, or expanding that page, needs a separate decision.
