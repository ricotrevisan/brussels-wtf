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

Coverage generation is selected independently of extraction and normalization. `COVERAGE_PROCESSOR=recorded` (the default) uses `RecordedCorpusCoverage` for the sealed historic and September selections. Those contracts match the complete source-backed publication input; source drift fails closed instead of receiving stale prose. `COVERAGE_PROCESSOR=openrouter` selects the network-backed provider described below. Ordinary tests use controlled HTTP responses and make no paid or nondeterministic calls. Selecting OpenRouter does not replace the recorded normalizer or make arbitrary new PDFs supported.


## Runtime generation controls

The application reads these variables when the release starts:

- `COVERAGE_GENERATION_MODE`: `disabled`, `recorded`, or `paid`. The current default is `recorded` so the hash-pinned Ixelles contract remains available. Invalid values stop startup.
- `BACKFILL_GENERATION_ENABLED`: strict `true` or `false`, default `false`.
- `COVERAGE_BACKFILL_MAX_BATCH_SIZE`: positive meeting count, default `10`.
- `COVERAGE_MONTHLY_BUDGET_CENTS`: required positive integer only in `paid` mode. It is rejected in the other modes.

`disabled` still permits polling, retrieval, extraction, OCR, and normalization. Coverage jobs finish without calling processor metadata or a provider, pages remain private, and no publication review case is opened merely because generation is off.

`recorded` permits only a processor that declares recorded billing and no network access. Recorded runs reserve no money. `paid` permits only a network-backed processor and requires the monthly budget. OpenRouter uses `paid` mode even when the selected model is free, because the chain includes a paid fallback. Paid mode with the recorded processor, or recorded mode with OpenRouter, fails startup.

`OPENROUTER_API_KEY` is the credential for `COVERAGE_PROCESSOR=openrouter`. Paid mode rejects a missing or malformed key without echoing it. Disabled mode permits stopping generation without a key. Store the production value as a Coolify secret; do not put resolved credentials in files, logs, commands, issues, or commits. Runtime selection applies to development and production; ordinary tests ignore these operator environment settings.

Workers re-read the effective policy immediately before canonical French generation and again before each translation. To stop paid work, set `COVERAGE_GENERATION_MODE=disabled` and `BACKFILL_GENERATION_ENABLED=false` in Coolify, remove `COVERAGE_MONTHLY_BUDGET_CENTS` (accepted only in paid mode), and restart the app process. Jobs already queued before the restart then finish without another provider call. The OCR process may keep running because this switch does not stop extraction.

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
7. Only when all eight meetings contain the exact 24 authoritative item identifiers and no related case is open does **Confirm dossier links and queue scoped coverage** appear. This authenticated operation records audit actions for the two exact-identifier `OPP/2026/185` dossier links, then creates a separate historical `CoverageBatch` limited to the 24 manifest items. Authorizing this bounded generation operation does not assert that a person reviewed the generated content.
8. Recorded publication creates three zero-network coverage runs per meeting and passes the normal locale, evidence, citation, provenance, and ambiguity gates. Runs keep their actual AI-generation or machine-translation provenance; they do not receive a `human-reviewed` label unless a separate review really occurred. Refreshing the batch after all eight pages publish closes it as `completed`.

Re-running import, dossier preparation, or coverage preparation is idempotent. Existing published revisions retain their recorded provenance immutably; this policy changes what new corpus queue operations assert. A sealed batch never expands its meeting membership. To accept changed official bytes, review the new municipal document, update the research note and manifest, replace the release-owned file, and deploy a new manifest digest. Do not edit a persisted batch or bypass its review case.

## OpenRouter inference

Work is tracked in [Add budgeted OpenRouter coverage with ordered model fallbacks](https://github.com/ricotrevisan/brussels-wtf/issues/95).

The ordered model chain is pinned in code:

1. `stealth/union-alpha` — user-selected primary, currently free.
2. `google/gemma-4-31b-it:free` — free fallback.
3. `deepseek/deepseek-v4-flash-0731` — fast paid fallback. The inspected catalog on 2026-09-17 listed $0.06/million input tokens and $0.12/million output tokens, less than V4.1 Flash or Gemini Flash Lite. This is a price observation, not a quality benchmark or latency guarantee.

Each generation operation starts with an OpenRouter request for the ordered free-stage models, Union Alpha then Gemma. This stage has a 20-second wall limit. A retryable provider or transport failure can advance once to a separate DeepSeek request with `reasoning.enabled=false`, using only the time remaining in the overall 70-second deadline. The reasoning option is never sent to the free stage, so parameter filtering cannot silently remove Union Alpha for lacking that option. A structured HTTP 404 with error code 404 and a recognized no-compatible-endpoints message also permits fallback; arbitrary 404s remain terminal. Authentication/payment failures and successful but invalid content do not advance to another model. Req does not retry or follow redirects. Existing publication jobs retain their bounded retry policy. Each request caps input at 64 KiB, encoded request at 128 KiB, response at 256 KiB, output at 8,192 tokens (a reasoning model can spend thousands of tokens thinking before the JSON answer; 4,096 truncated a real two-item generation), connect timeout at 10 seconds, receive timeout at 60 seconds and total wall timeout at 70 seconds. Keepalive bytes cannot prolong the total deadline; a cancelled request keeps its cost uncertain. Oversized inputs are rejected rather than truncated.

`provider.max_price` caps prompt/completion at $0.06/$0.18 per million tokens and per-request fees at zero. The initial $0.12 output ceiling selected an endpoint without JSON response-format support; live routing returned 404. The $0.18 ceiling admits compatible endpoints, including the inspected $0.03/$0.13 OpenInference and $0.06/$0.18 DeepInfra routes. These ceilings filter available endpoints; a price increase or unavailable provider fails closed. Every operation reserves a conservative 3 cents before network access, covering the bounded three-model chain. Known stage costs are rounded **up** to cents and summed for the existing ledger. If any attempted stage has unknown cost, the aggregate cost remains unknown even when the final stage succeeds. Missing/uncertain cost is never zero: the reservation's maximum is charged by the existing reconciliation contract. Thus ledger spend can exceed actual provider spend for sub-cent calls. Model pricing or caps require a versioned code change, not an unreviewed environment override.

Requests use `data_collection: "deny"`. This is **not** a zero-retention promise. Union Alpha's official page says its anonymous provider may retain prompts/completions; provider policy metadata is not sufficient to guarantee this model passes the deny filter. Do not relax privacy settings to force the primary or free fallback. Each response must identify an allowlisted actual model, retained in immutable run provenance and usage. Only the publication-input projection or canonical translation text is sent; no archive access, tools, browsing, credentials, reviewer notes or suggestion bodies are provided. Exact input/output key validation rejects unexpected fields. A schema and valid claim references do not independently prove every generated sentence is entailed by its evidence; real-source language/faithfulness checks are required before scaling.

### Development

The committed `.env.openrouter.dev` contains only the 1Password reference `op://Dev/openrouter/brussels-wtf-dev`, not its value. It explicitly opts into OpenRouter with a **$1/month development ceiling** and backfill generation off:

```bash
op run --env-file=.env.openrouter.dev -- mix phx.server
```

Use the normal isolated test database for contract checks. Ordinary tests never call OpenRouter. Never point these tests at production storage. The opt-in check makes at most three budget-reserved operations (up to six HTTP requests across their bounded stages) using the two already published Ixelles 269 proposal interpretations. It checks structured output, not a new PDF normalizer or a full semantic benchmark, and never publishes:

```bash
op run --env-file=.env.openrouter.dev -- env ERL_FLAGS='+S 4:4' \
  MIX_TEST_PARTITION=_live mix test --include external test/contracts/openrouter_live_test.exs
```

It prints only sanitized model/usage/status receipts. Test-database reservations roll back; actual OpenRouter charges do not. Do not repeatedly run it to bypass a real spending limit.

### Production activation

This implementation is not evidence of a deployment or a model-quality acceptance. Before activation, pass normal release checks and a bounded real-source FR/NL/EN check, then configure the reviewed release in Coolify:

- `COVERAGE_PROCESSOR=openrouter`
- `OPENROUTER_API_KEY`: secret value from **Dev → openrouter → brussels-wtf-prod** (not the dev field)
- `COVERAGE_GENERATION_MODE=paid`
- `COVERAGE_MONTHLY_BUDGET_CENTS`: the operator-approved positive USD-cent ceiling; **no production default**
- `BACKFILL_GENERATION_ENABLED=false`

Inspect queued publication work before switching modes. Provider activation does not authorize replaying a historical backlog or publishing unsupported new sources. Keep the existing recorded normalizer, evidence gates and all-locale publication transaction intact. Disable generation with `COVERAGE_GENERATION_MODE=disabled` and `BACKFILL_GENERATION_ENABLED=false`, remove `COVERAGE_MONTHLY_BUDGET_CENTS` (it is valid only in paid mode), and restart. Returning to recorded mode also requires `COVERAGE_PROCESSOR=recorded` and removal of the paid-only budget setting. Prior public revisions remain preserved.

Official API references: [ordered fallbacks](https://openrouter.ai/docs/guides/routing/model-fallbacks), [provider pricing/privacy filters](https://openrouter.ai/docs/guides/routing/provider-selection), [usage accounting](https://openrouter.ai/docs/cookbook/administration/usage-accounting), [provider logging](https://openrouter.ai/docs/guides/privacy/provider-logging).

### Implementation checkpoint — 2026-09-17

The dev key authenticated successfully. The staged adapter completed canonical French and Dutch/English translations for Ixelles 269 items 38 and 39 in 52.1 seconds. Each free stage returned HTTP 504 and the paid DeepSeek stage succeeded. A content review found a Dutch modifier-scope defect; after tightening the translation instruction, one Dutch-only recheck against the saved French canonical preserved both price and quantity revisions. FR and EN were not regenerated after that prompt change. These are bounded fixture acceptance results, not a guarantee for other inputs or evidence that the primary model succeeded. All failed-stage costs remained unknown and reconciliation used the conservative reservation ceiling. No production activation, publication, or historical replay was performed.
