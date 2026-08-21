# Automatic meeting-page publication

[#17: Generate and publish upcoming Ixelles coverage](https://github.com/ricotrevisan/brussels-wtf/issues/17) adds evidence-gated automatic publication.

## Flow

1. Normalization persists the current meeting, agenda items, proposals, and official evidence.
2. A `publish`-queue job invokes the named `generate_coverage` Ash action, which rebuilds a deterministic publication input from that stored state.
3. The configured coverage processor generates canonical French coverage, then translates that exact output to Dutch and English.
4. Every processor execution, including a failed or exceptional call, is retained as an immutable coverage run with input/output hashes, processor version, configuration hash, method, timing, usage, failure classification, and canonical-parent relationship.
5. The named publication-gate action checks complete page and item variants, normalized claim references, official evidence and citations, applicable provenance, a coherent current run chain, and the absence of open normalization or evidence review cases for the meeting.
6. The page becomes public only after the complete revision passes. No reviewer approval is required.

The variant upserts and page publication happen in one database transaction. Published variants reject direct mutation; the transaction first stages the page as a draft, writes the complete replacement, records its immutable revision, and only then invokes the gated publish action. That action requires the revision content, timestamp, input hash, and exact run trio to match the gated live variants. A failed or interrupted initial generation leaves a private draft. A failed later revision preserves the complete prior public revision. A complete later generation atomically replaces all locale variants and updates the published revision. Every successful publication also appends an immutable revision snapshot linked by foreign keys to the exact French, Dutch, and English coverage runs; those runs retain its normalized evidence input.

## Failures and retry

A gate failure preserves the last complete publication state, stores typed failure details on the page, and opens one deduplicated `publication` review case for the publication-input hash. A later successful generation resolves that gate case. Common failure codes include:

- `missing_page_variant`
- `missing_coverage_variant`
- `missing_evidence`
- `missing_citation`
- `unofficial_citation`
- `missing_evidence_excerpt`
- `missing_evidence_location`
- `missing_evidence_checksum`
- `unsupported_claim_reference`
- `missing_provenance`
- `stale_generation`
- `blocking_review_case`

Processor failures retain one coverage-run record per execution. Oban retries them up to its bounded `max_attempts`; the terminal attempt opens a deduplicated high-urgency publication review case. Diagnostics contain durable identifiers and safe classifications, never provider prompts, credentials, private object keys, or response bodies.

## Processor configuration

Coverage generation is selected through the `:brussels_wtf, :coverage_processor` application configuration, independently of extraction and normalization. Production uses a deterministic recorded contract for the initial Ixelles proposal. That contract matches the commune, meeting, normalized wording, claim text, state, and official citation before returning its recorded copy; source drift fails closed instead of receiving stale prose. Tests use a fixture-backed stub and make no paid or nondeterministic calls. A later benchmark may replace the provider through the same processor seam without changing the publication contract.


## Runtime generation controls

The application reads these variables when the release starts:

- `COVERAGE_GENERATION_MODE`: `disabled`, `recorded`, or `paid`. The current default is `recorded` so the hash-pinned Ixelles contract remains available. Invalid values stop startup.
- `BACKFILL_GENERATION_ENABLED`: strict `true` or `false`, default `false`.
- `COVERAGE_BACKFILL_MAX_BATCH_SIZE`: positive meeting count, default `10`.
- `COVERAGE_MONTHLY_BUDGET_CENTS`: required positive integer only in `paid` mode. It is rejected in the other modes.

`disabled` still permits polling, retrieval, extraction, OCR, and normalization. Coverage jobs finish without calling processor metadata or a provider, pages remain private, and no publication review case is opened merely because generation is off.

`recorded` permits only a processor that declares recorded billing and no network access. Recorded runs reserve no money. `paid` permits only a network-backed paid processor and requires the monthly budget. No paid production processor is selected yet, so setting `paid` with the current recorded processor stops startup rather than falling back.

There are currently no accepted paid-provider credential variables. Do not put a provider key into the application until a provider adapter, credential name, request/output caps, conservative maximum-cost calculation, timeout, and retry contract have been reviewed. That later adapter must read its credential from a Coolify secret, reject missing or partial credentials at startup, and never expose the value in configuration errors, logs, usage records, or review diagnostics.

Workers re-read the effective policy immediately before canonical French generation and again before each translation. To stop paid work, set `COVERAGE_GENERATION_MODE=disabled` in Coolify and restart the app process. Jobs already queued before the restart then finish without another provider call. The OCR process may keep running because this switch does not stop extraction.

## Paid-call budget

A paid call must obtain a PostgreSQL reservation before provider use. The guarded update admits the call only when current spend plus outstanding reservations plus the conservative maximum charge for the capped request fits within the UTC calendar-month limit. Calls denied by the budget make no network request and do not flood the review inbox.

After a call, the reservation stores provider, model, meeting page, publication-input hash, operation, locale, retry, usage, and final cost when available. If final cost is unknown, the conservative maximum is charged. A transient reconciliation failure leaves the reservation held, blocks publication, and queues a durable reconciliation retry on the `publish` queue. If queuing fails, the original publication job fails so Oban retries it; exhausted reconciliation retries persist `reconciliation_failed` on the reservation and poison the month. If a provider reports a charge above its declared maximum, the reservation records `reconciliation_failed`, links the coverage run and usage, and holds the rest of that month's budget so no later paid call can be admitted. A paid adapter must cap provider output and calculate the upper bound before it can be enabled. A limit already persisted for the current month cannot be changed by restarting the release with another value.

## Historical coverage batches

Acquisition backfills retain their backfill scope through extraction and normalization and never imply permission to generate coverage. When `BACKFILL_GENERATION_ENABLED=true`, an authenticated reviewer can use **Coverage generation batch** on `/review` to submit a finite meeting-ID allowlist. The allowlist and reviewer are stored before one backfill generation job per meeting is inserted. The configured maximum batch size is enforced again in the domain function, not only by the form.


## Sealed real-corpus import

Issue 33 has a separate authenticated import path. It does not use unrestricted commune backfill and it does not authorize generation.

1. Sign in to `/review` as the configured reviewer.
2. In **Real corpus import batch**, submit the sealed meeting keys. The complete issue-33 run contains eight keys and nine documents.
3. The batch stores the manifest digest, exact keys, expected document count, expected bytes, requester, lifecycle, lineage IDs, and measurements before work starts.
4. Import jobs run serially on the `corpus` queue. They read only `priv/corpus/issue-33/sources/`; no municipal or provider network call occurs. The manifest permits at most eight meetings, 24 items, nine documents, and 2,000,000 bytes per document. It seals each official URL, discovery parent, and original capture time. The importer records a meeting-scoped locator and local bundle-check observation with no HTTP response fields. Each byte sequence is archived and read back before its source version enters extraction.
5. A byte-count or SHA-256 mismatch retains the observed bytes, opens an acquisition review case, blocks the batch, and does not enqueue extraction.
6. Use **Refresh report** to persist retrieval, stored-byte, OCR, normalization, review, generation, and publication measurements.
7. Only when all eight meetings contain the exact 24 authoritative item identifiers and no related case is open does **Verify dossier and queue coverage** appear. This authenticated action records the actor, review time, manifest digest, two manually verified `OPP/2026/185` links, and their audit actions. It then creates a separate historical `CoverageBatch` carrying the same content-review provenance.
8. Recorded publication creates three zero-network coverage runs per meeting. Each run carries the authenticated human-review label, while preserving the original AI-generation or machine-translation label. The immutable publication revision records the review actor, time, and manifest digest. Refreshing the batch after all eight pages publish closes it as `completed`.

Re-running import, dossier preparation, or coverage preparation is idempotent. A sealed batch never expands its meeting membership. To accept changed official bytes, review the new municipal document, update the research note and manifest, replace the release-owned file, and deploy a new manifest digest. Do not edit a persisted batch or bypass its review case.
