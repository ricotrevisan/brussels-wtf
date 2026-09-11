# Current-coverage scope — 11 September 2026

## Recommendation

A legitimate small extension is feasible without a paid provider: **four new September meetings, one explicitly selected agenda item per commune, using four hash-pinned PDFs and recorded FR/NL/EN coverage**. This is a proposed implementation slice, not authorization to import, publish, or spend. Start with Ixelles 269 if delivery must be sequential. Repair Uccle current-index discovery separately; importing one Uccle document does not fix continuous acquisition.

Do not append these meetings to the sealed issue-33 batch or replace its existing meetings. That contract deliberately requires eight meetings and 24 items. Add a separately bounded current-coverage contract through the existing normalization and coverage interfaces, preserving issue-33 behavior. Do not weaken source-hash checks, evidence checks, or review gates to make new material pass.

## Method and limits

Read `AGENTS.md`, `CONTEXT.md`, the MVP specification and all four accepted ADRs. Inspected the configured processors, corpus manifest/importer, discovery adapters, polling path, generation controls, and public coverage projection. On 2026-09-11, fetched five official indexes and six directly linked PDFs. All municipal GETs returned HTTP 200. Index requests were capped at 2 MB; PDF requests at 2 MB except the two Ixelles requests, capped at 5 MB. No guessed source URLs, archive crawl, paid generation, production database access, or production writes occurred.

Ran the four repository adapters directly with native Elixir 1.18.3/OTP 27 against the saved HTML. Loaded only the adapter behavior and adapter modules with `elixir -r`; did not start the application or jobs. Ran `pdfinfo` and `pdftotext -layout` against the six saved PDFs. This proves local native readability, **not** passage through the production image's page-level quality gate. No new normalization or publication acceptance test was run.

A single read-only request to the documented public [coverage route](https://brussels-wtf.nocode-to-knowcode.com/coverage?lang=en) returned HTTP 503, `no available server`. Therefore this note makes no claim about today's deployed publication count, last successful application poll, or current review-case count. The source-code support boundary below is distinct from deployment state. Municipal HTTP cache dates and PDF creation metadata are not treated as authoritative publication timestamps.

## What the checked code actually supports

[Configuration](../../config/config.exs) selects `RecordedCorpus` for normalization and `RecordedCorpusCoverage` for coverage. It does not select the older one-item `RecordedIxelles268`/`RecordedCoverage` tracer. Documentation that still describes a single Ixelles production contract is stale relative to this configuration.

The [manifest](../../priv/corpus/issue-33/manifest.json) contains:

| Commune | Meeting identities/dates | Sealed document roles |
| --- | --- | --- |
| Ixelles | 267 — 2026-06-11; 268 — 2026-07-02 | Minutes; agenda |
| Uccle | 2025-06-26; 2026-04-23 | Register; explanatory note |
| Forest | 2025-04-22; 2026-03-24 | Minutes for each |
| City of Brussels | 2026-06-08; 2026-06-29 | Agenda; agenda plus supplement |

There are nine sealed source files and three selected items per meeting. This is sample coverage, not complete enumeration of eight agendas. Forest outcome corrections are a separate repair and are not endorsed or implemented by this scope note.

Important boundaries:

- [Manifest normalization](../../lib/brussels_wtf/corpus/manifest.ex) selects a source by exact SHA-256, then checks source/item markers on cited pages. An unknown hash returns `:processor_unimplemented`. None of the six newly fetched PDF hashes below is in the existing bundle.
- [Recorded coverage](../../lib/brussels_wtf/processors/recorded_corpus_coverage.ex) returns copy only for the exact complete normalized publication contract. An unknown meeting or changed wording, claim, outcome, evidence, source hash, or item set cannot obtain fresh copy merely by retrying.
- [Pipeline normalization](../../lib/brussels_wtf/ingestion/pipeline.ex) routes an unavailable normalizer into a private [normalization review case](../../lib/brussels_wtf/ingestion/normalization_review.ex). Successful discovery or extraction does not imply publishable coverage.
- [The importer](../../lib/brussels_wtf/corpus/import.ex) is issue-33-specific: the allowlist, completion counts, dossier preparation, and manifest digest are sealed. Changing only an environment variable or inserting a ninth meeting into that JSON is not an extension strategy.
- [Normalization processor provenance](../../lib/brussels_wtf/processors.ex) currently incorporates the processor module, manifest module, and issue-33 manifest digest. A new recorded contract must participate in this provenance; external contract data must not change silently while queued work keeps an old identity.
- [PublicationGate](../../lib/brussels_wtf/council/publication_gate.ex) and [review blocking](../../lib/brussels_wtf/review.ex) retain claim evidence, current run-chain, all-language, and meeting-related open normalization/evidence-case checks. An item allowlist does not automatically waive a blocking case elsewhere in its meeting.
- [CoverageStatus](../../lib/brussels_wtf/coverage_status.ex) is a bounded read model, not a generator. Its last-90/next-30-day window and 200-row limit describe discovered documents. An index check is not proof of complete download, normalization, or publication. A discovered minutes/register locator is not a verified item outcome.

These are useful existing seams, not a general current-document normalizer. Paying for generation alone would not repair their support boundary.

## Official current material and acquisition results

Each meeting date below is supported by its index context and downloaded agenda heading. The source roles are pre-meeting agenda roles, even where the meeting date has passed.

| Commune | Current official material observed | Adapter result on captured HTML | Final-evidence limit |
| --- | --- | --- | --- |
| Ixelles | [Council index](https://www.ixelles.be/site/11-Ordres-du-jour-et-proces-verbaux?langue=fr): 269, 2026-09-17, agenda and project dossiers | Success: 23 locators; latest document-bearing date 2026-09-17 | No minutes linked for 269 or 268 in inspected rows. Future empty rows are not evidence of available agendas. |
| Uccle | [Current council page](https://www.uccle.be/fr/ma-commune/le-conseil-communal): 2026-09-10, base/complementary agendas and notes | Current page fails `{:invalid_index, :missing_meeting_tables}` | The September 10 register row has no link. An empty row is not proof that no official final record exists elsewhere. |
| Forest | [Council index](https://forest.brussels/fr/publications/conseil-communal-1): 2026-09-01, complementary agenda and complementary notes | Success: 95 locators; latest date 2026-09-01 | No minutes link in the September 1 card. This says nothing conclusive about records elsewhere. |
| City of Brussels | [2026 council index](https://www.brussels.be/agenda-reports-and-motions-city-council?field_date_document_value=2026): 2026-09-07, agenda, supplement, base and supplement item-document listings | Success: 34 root locators; latest date 2026-09-07 | No minutes link in the inspected September 7 section. Child attachments were not fetched in this investigation. |

### Uccle has a separate acquisition defect

The [commune registry](../../lib/brussels_wtf/communes.ex) points Uccle at the [archive](https://www.uccle.be/fr/ma-commune/le-conseil-communal/archives-du-Conseil-communal). That captured page starts at 2025; its adapter run returns 1,409 locators, with newest meeting 2025-12-18. The current page instead has 2026 tables with day/month captions but lacks the numeric `<h2>YEAR</h2>` sections required by [Uccle.discover/2](../../lib/brussels_wtf/communes/uccle.ex).

The [polling path](../../lib/brussels_wtf/ingestion/pipeline.ex) retrieves `commune.index_url`; the previous-year scope filters discovered locators rather than introducing a different current-year root. Thus neither an archive-only successful poll nor changing the URL alone establishes working 2026 discovery.

Bounded repair: support the real current-page shape with explicit authoritative year context; retain archive discovery as its own source context; test current/previous-year routing and rollover. Keep exact hrefs, parent indexes, roles, and disappearance history. Reject ambiguous dates instead of guessing from filename patterns or the system year. A successful current-index check must refer to the actual current index, not an archive replay.

## Four concrete selected-item candidates

These are **research-supported agenda descriptions, not adopted decisions or ready-made public variants**. They demonstrate that small useful selections need no generic model activation. Public copy must retain this limit.

| Meeting/item | Exact primary evidence | Safe explanation supported by that source | Not supported |
| --- | --- | --- | --- |
| Ixelles 269, item 39 | [Agenda, PDF p.7](https://www.ixelles.be/uploads/conseil/odj/269.pdf#page=7) | School-furniture procurement `2023-1011` through the CREAT purchasing body is scheduled for consideration, with an additional proposed EUR 143,000 including VAT and budget entries for 2026–2028. | Council approval, expenditure actually incurred, delivery, supplier ownership, or a final award. |
| Uccle 2026-09-10, item 8 | [Complementary agenda, PDF p.2](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-09-10-ODJC-U1180_fr_nl.pdf#page=2) | The agenda lists an agreement concerning underground clothing containers on avenue Circulaire and avenue Homborchveld. | Adoption, installation date, cost, operator identity, or completed works. |
| Forest 2026-09-01, item 5 | [Complementary agenda, PDF p.2](https://forest.brussels/sites/default/files/publications/ordre-du-jour/2026-08/CC-%2001092026%20-%20agenda%20compl%C3%A9mentaire.pdf#page=2) | The agenda lists authorization and designation of a lawyer for an annulment challenge before the Constitutional Court against the law of 25 May 2026 on merging multi-commune police zones. | Authorization actually granted, an appeal actually filed, or any court outcome. This is unrelated to the older Forest outcome repair. |
| City 2026-09-07, supplement item 188; workflow `2728523` | [Supplement, PDF p.2](https://www.brussels.be/sites/default/files/OJSUP07092026.pdf#page=2) | Dossier `OPP/2026/188` concerns proposed facade and glass-roof renovation at Les Six-Jetons primary school, rue des Six-Jetons 55, 1000 Brussels. The listed principle-stage expenditure is EUR 1,802,155.03 including VAT; the conditional tranche is subject to approval of a budget modification. | A final award, named contractor, council adoption, work completion, or a link to the different existing dossier `OPP/2026/185`. |

On the research date, Ixelles September 17 is upcoming. Uccle September 10, Forest September 1, and City September 7 are past dates: their coverage belongs in **Awaiting documented outcome**, not Coming up or What they decided. A later agenda item proposing approval of earlier minutes is not those earlier minutes and does not verify their individual outcomes.

### Exact PDF observations

All fetched on 2026-09-11; all HTTP 200. Page counts are from local Poppler. The four starred files alone total **876,769 bytes**, 51 pages.

| Source | Bytes | Pages | SHA-256 |
| --- | ---: | ---: | --- |
| *[Ixelles 269 agenda](https://www.ixelles.be/uploads/conseil/odj/269.pdf) | 211,045 | 24 | `eefafbaf225c2d00e501e1d826ddcde084bef7dfbf3c9b2a034803da39a11670` |
| [Ixelles 269 project dossiers](https://www.ixelles.be/uploads/conseil/projets/269.pdf) | 3,510,470 | 505 | `8b7e2af2f8868e4c51594f57ddaa0dbf8299ff7660f35850bc0d296b8bf11cc2` |
| *[Uccle September 10 complementary agenda](https://www.uccle.be/sites/default/files/filemanager/Legal/CC-GR/CC-2026-09-10-ODJC-U1180_fr_nl.pdf) | 100,573 | 11 | `b853efaeb02cf1b3cf22488b606ca273d6a6bf7112dcb43d9f1788273be85d3d` |
| *[Forest September 1 complementary agenda](https://forest.brussels/sites/default/files/publications/ordre-du-jour/2026-08/CC-%2001092026%20-%20agenda%20compl%C3%A9mentaire.pdf) | 98,894 | 10 | `24c7f42dc7253ae615105d088125356c90b88644c4d72ddad0fc90e3d56a186a` |
| [City September 7 agenda](https://www.brussels.be/sites/default/files/OJ20260907.pdf) | 502,227 | 21 | `adae1cffbbdd56a8715882285e952d49c41efe2b22ec96fe177cc85b75a138fa` |
| *[City September 7 supplement](https://www.brussels.be/sites/default/files/OJSUP07092026.pdf) | 466,257 | 6 | `2a8b3180cf9614530f54ec1e19bd08da107c3cb73f0088d2073cb2339feb6a57` |

The Ixelles project dossier exceeds both the issue-33 importer's 2,000,000-byte cap and the default extraction limit of 500 pages. Do not silently raise either limit. An agenda-only selection is feasible within existing size limits; processing that complete dossier needs a separately measured resource decision. Related unsupported-source cases still require their ordinary audited treatment, not bulk closure to unblock a page.

## Acceptance and decisions

### Achievable recorded extension

1. Explicitly approve the four meeting identities and four item identifiers above, or deliver Ixelles alone first. Freeze a **new** bounded contract; retain the existing issue-33 contract and history.
2. Archive complete official source bytes with their exact parent indexes, capture times, roles, and hashes. Do not treat a local research fetch as an application retrieval observation or production freshness check.
3. Supply source-specific recorded normalization with identity and excerpt checks confined to the cited pages. Preserve complementary-agenda/supplement roles; do not infer item continuity or dispositions from generic words such as `Approbation`.
4. Supply separately versioned canonical French and Dutch/English recorded copy keyed to the complete publication input. Use true AI/translation provenance; batch authorization alone does not mean human review.
5. Exercise the real native-extraction → normalization → scoped generation → ordinary gate → public route seam in isolation. Test changed bytes, changed claims, out-of-allowlist items, open blocking cases, repeat execution, and preservation of old publications. Four successful new pages require 12 recorded coverage runs and zero provider network calls; this is an acceptance target, not an observed result.
6. Demonstrate the correct dated state and selected-item scope in all languages. Keep full-agenda completeness unknown. Verify Uccle current discovery independently. No paid generation or production deployment is authorized by this note.

### Requires an explicit later decision

- General normalization for arbitrary current PDFs, rather than reviewed hash-pinned selections.
- A paid provider/model and credential contract; FR/NL/EN quality benchmark; request/output caps; maximum-cost reservation; timeouts and bounded retries; a chosen monthly budget. [GenerationControl](../../lib/brussels_wtf/council/generation_control.ex) already fails closed: `paid` with the current recorded processor is invalid. Increasing a budget does not create a provider adapter or normalizer.
- Larger-document processing, including the 505-page Ixelles dossier. Local extraction alone is not a capacity benchmark or approval to increase production limits.
- Complete four-commune coverage, unrestricted backfill, transcription, final decisions without final records, or new company/person relationships. None follows from this small extension.

## Captured index identities

These hashes identify the exact HTML inspected, not permanent versions of the URLs:

| Index | Bytes | SHA-256 |
| --- | ---: | --- |
| Ixelles | 26,501 | `87948b5001a88997857d697d0c0a2b79411cd10cc66a2413f3c66b6ff9782250` |
| Uccle current | 253,591 | `0441ccffc940431b61213442525c5c2456af1788f68653c8f3d6715f0d61e943` |
| Uccle archive | 971,554 | `6f862e79496e49453face3bad2f2004c3b597a10237b69bd35a2fbbf52d33c5d` |
| Forest | 72,097 | `a577d4281db5239eae685588bb0ddb39b1a87bad2524dcd569fca3ae4c1c7bb7` |
| City 2026 | 57,009 | `bf0ef00cebfb73838fee395267bafe32e2cb46db458ec7c510fccd4e8743b489` |

Local working captures and extracted text are in `/tmp/current-coverage-scope-20260911/`. They are not a durable production archive. Only this research note was added to the repository; no code, corpus, configuration, or production state was changed by this research.
