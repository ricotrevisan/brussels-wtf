# Bounded September 2026 coverage

Issue [#79](https://github.com/ricotrevisan/brussels-wtf/issues/79) adds a separate recorded selection. It does not extend or reopen the issue-33 import batch. The existing eight-meeting/24-item import and its historical records stay unchanged.

## Fixed selection

`priv/corpus/current-20260911/manifest.json` records the four official source URLs, parent indexes, full-file SHA-256 hashes, byte sizes, retrieval times, cited PDF pages, source excerpts and FR/NL/EN interpretations. It contains exactly one PDF and two proposal items per meeting.

| Commune | Meeting | Items | Evidence pages |
| --- | --- | --- | --- |
| Ixelles | `269`, 2026-09-17 | 38, 39 | 7 |
| Forest | 2026-09-01 | 13, 45 | 25–27; 110–111 |
| Uccle | 2026-09-10 | 12, 38 | 11–13; 56–57 |
| City of Brussels | 2026-09-07 | 30 / workflow `2722248`; 31 / workflow `2728690` | 5 |

All eight outcomes remain **unknown**. Preparatory “Décide”, “Beslist” and “Approbation” do not prove adoption. September meetings that have passed remain awaiting outcomes. Ixelles is upcoming as observed on 11 September 2026.

Important limits:

- Ixelles 39 is an additional €143,000 including VAT, not the whole furniture contract value. The separate projects PDF exceeds the 500-page processing limit; the selected agenda is sufficient for these two bounded items.
- Forest 13 proposes a US$50,000 youth climate grant agreement. Do not substitute a current EUR value for the source’s dated conversion. Forest 45 concerns a €9,410 regional contribution against an €18,500 municipal taxi-voucher budget, not total funding.
- Uccle 12 attributes the €466,733.12 estimate and its VAT/revision wording to the notes; no award is established. Uccle 38 estimates €5,500 per year for the ebook agreement; the VAT basis is not stated.
- City 31 proposes a €484,950 including-VAT lift procurement, funded by borrowing. No contractor or award is established. City 13 is deliberately excluded: its €6.2m amount and the supplement’s similar €7.5m item lack a verified continuity or replacement link.
- Retrieval times, HTTP Last-Modified, filename dates and PDF metadata are not municipal publication times. Those publication times remain unknown here.
- Canonical FR is AI-generated. NL/EN are machine translations of that recorded canonical output. Operator authorization is not human content review.

## Existing domain path

The fixed registry extends `Manifest` hash/identity lookup and exact recorded claim contracts. The normalization and coverage processor configuration hashes include both fixed selections. New records carry the new configuration identity. Historical source versions, processing runs and publication revisions remain immutable.

There is no new importer, upload endpoint, arbitrary PDF normalizer, dossier link or paid provider. `Manifest.load!/0` and `digest/0` still refer to issue-33. Use `load!("current-20260911")` to read the new selection.

After separately authorized rollout, operations can use the existing domain path:

1. Resolve each exact official URL and immutable source hash. Reuse matching retained versions; do not overwrite them. If a selected source is missing, acquire its official locator through the ordinary ingestion pipeline. The Uccle current-index adapter repair is separate.
2. Verify the archived full bytes and size, not only the database hash field. Verify the accepted native-text artifact, checksum, page evidence and deployed processor metadata. Local Poppler acceptance is not a claim about the deployed Poppler version.
3. Use `Ingestion.Pipeline.extract/3` as needed, then `normalize/5` with the accepted run, exact source citation URL and `:backfill`. Retain prior failed runs and source history. Unknown hashes and mismatched current claim contracts must fail closed.
4. Build the four existing meeting IDs from the exact commune/date/municipal identities. Call `Council.request_coverage_batch!/2` with the authenticated reviewer and `item_scopes` containing exactly the two manifest item keys for each meeting. Do not queue historical meetings or an unscoped batch. Backfill generation must be explicitly enabled.
5. Let the existing publication worker and gate validate the full source/claim input, canonical lineage and complete three-locale revision. Inspect the public pages, outcome labels, source anchors and zero-network generation provenance. A failed locale must not expose a partial revision.

These are operational checks, not authorization to run production mutations. Source availability, source parsing, interpretation support, publication readiness and actual publication are separate states.

## Reproducible checks without publishing raw documents

Full new PDFs, index HTML and extraction captures stay in private evidence storage until each source has a rights/privacy disposition. They are not Git or public-content fixtures. The contract stores only selected administrative excerpts and interpretations; it does not claim an open licence for the full sources.

Normal deterministic CI tests use minimal source excerpts and recorded contracts. The full native principal test is explicitly tagged `external` because it needs separately supplied, hash-verified private fixtures. Despite the tag, it uses the HTTP stub and makes no network or provider requests:

```text
ERL_FLAGS='+S 4:4' MIX_TEST_PARTITION=_current \
CURRENT_CORPUS_SOURCE_DIR=/private/verified-current-sources \
mix test --include external test/brussels_wtf/corpus/current_acceptance_test.exs
```

Fixture filenames are `<source name>.pdf` from the manifest. The test checks real full-file hashes and sizes, ordinary retrieval observations, native Poppler acceptance, normalization, exact two-item scopes, all three public locales, unknown outcomes, honest provenance and stable source/item identities on replay. It does not replace a production image check, a representative-reader check, or the two real polling cycles tracked separately.
