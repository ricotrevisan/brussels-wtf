# Uccle current acquisition (issue #80)

## Contract and limits

`BrusselsWtf.Communes.Uccle.discover/2` accepts captured HTML and its exact
parent index URL. It returns exact discovered locators and meeting context,
or `{:error, {:invalid_index, reason}}`. It does not fetch PDFs or publish.

The official current page does not print a year on its meeting-table captions.
The audited layout has one council-body section headed
`Agenda des séances publiques du Conseil communal`, followed immediately by a
list of full upcoming dates, then the document-bearing meeting tables.
The adapter uses that **same-section calendar as index evidence**. It does not
pretend the table captions print complete dates.

Current support is deliberately pinned to the reviewed **2026** layout:

- Every calendar entry must be a valid dated Thursday in 2026.
- Every linked table caption must be an unambiguous day/month date strictly
  before the earliest listed calendar session.
- Missing/mixed/changed years, invalid dates, contradictory caption years,
  calendar/archive section mixtures, and possible December leftovers fail
  closed. The poll retains the rejected index bytes and opens parser review.
- A table for the same date still listed in the calendar also fails. This is
  an explicit conservative limitation, not complete upcoming-agenda support.
- Day/month alone cannot distinguish a prior-year January leftover from this
  January. Seven independently retrieved official agenda first pages confirm
  all seven dates in the audited capture; they do not prove arbitrary future
  page edits. Normalization must independently verify source identity before
  coverage can publish. Do not relax that boundary.

This is not a perpetual year assumption. The system clock, footer/service
notices, and question/motion filenames never supply the year. Changed year
context requires renewed source review and a tested adapter update.

## Routing and retained history

`BrusselsWtf.Communes.poll_index_url/2` selects these explicit official roots:

- Current/scheduled/default poll-now:
  `https://www.uccle.be/fr/ma-commune/le-conseil-communal`
- Previous-year and explicit backfill:
  `https://www.uccle.be/fr/ma-commune/le-conseil-communal/archives-du-Conseil-communal`

This selection applies when the persisted commune points to either official
root, including the legacy archive configuration. Custom roots remain
unchanged. The same selection governs HTTP 304 replay. Previous-year scope
retains its ordinary year filter; historical acquisition does not authorize
coverage generation.

Changing the selected poll root does not rewrite any locator, parent index,
source version, hash, observation, or publication. Archive and current index
bytes remain separately versioned. A missing register link creates no register
locator and no final outcome.

The registry now defaults new Uccle records to the current root. Existing
commune configuration rows are not migrated by this repair. Acquisition still
selects the correct root, but a public view of the stored `commune.index_url`
may continue to link to the archive. An authorized operator may update only
that commune configuration through the existing `Ingestion.create_commune!`
upsert, preserving its slug/identity and name. Inspect the existing row first;
do not modify source locators or perform bulk URL replacements.

## Audited source proof

See [fixture provenance](../../test/support/fixtures/uccle/README.md) for exact
URLs, SHA-256 hashes, sizes, and the seven printed PDF page-1 meeting headings.
The full current HTML captured on 2026-09-11 has SHA-256
`0441ccffc940431b61213442525c5c2456af1788f68653c8f3d6715f0d61e943`.
The adapter yields 113 locators across seven 2026 meeting dates; latest is
September 10, with exactly four base/complementary agenda/note locators and
no register link. October 15 is calendar-only, not an available-document claim.

The full archive capture has SHA-256
`6f862e79496e49453face3bad2f2004c3b597a10237b69bd35a2fbbf52d33c5d`.
It still yields 1,409 locators, latest December 18, 2025. Local research GETs are
not production poll observations, extraction acceptance, or publication proof.

## Safe year/layout update

1. Capture the official current index and response metadata. Record exact URL,
   retrieval time, bytes, and hash. Keep the rejected production snapshot.
2. Inspect the calendar/table semantic grouping and every linked table caption.
   Independently verify full dates from authoritative main-document headings;
   do not derive dates from filenames or advance the pin from the wall clock.
3. If dates remain ambiguous, leave the review unresolved. Do not publish
   guessed meeting context. No generic extra-fetch pipeline is introduced here.
4. Add a minimal captured fixture and source-provenance note. Update the
   `@audited_current_year` pin only with this new evidence. A same-date upcoming
   table or changed layout needs its own explicit evidence rule and tests;
   do not just remove the ordering guard.
5. Run the adapter and public poll tests. Cover missing/mixed/changed years,
   rollover, prior-year leftovers, malformed filenames, unknown roles, blank
   registers, archive continuity, current/archive 304 replay, disappearance,
   immutable index history, and the ordinary publication evidence boundary.
6. Run the full native suite in an isolated test namespace. A typical command:
   `ERL_FLAGS='+S 4:4' MIX_TEST_PARTITION='_uccle' mix test`.
7. Deploy or request a bounded production poll only with separate operational
   authorization. Inspect the actual current-index observation and any review
   cases. Discovery alone does not mean downloads, normalization, or coverage
   are complete. Never bulk-close unsupported-source cases to force publication.
