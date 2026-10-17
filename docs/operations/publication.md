# Automatic meeting-page publication

[#17: Generate and publish upcoming Ixelles coverage](https://github.com/ricotrevisan/brussels-wtf/issues/17) adds evidence-gated automatic publication.

## What a page covers

A published meeting page covers the votable points of the meeting. The publication input is
the publishable set: only agenda items that carry at least one current proposal or decision
claim. Real agendas also contain information, interpellation, communication, and other
non-votable points. Those points carry no claim and no official evidence, so they are not
summarized and do not appear as coverage items. They stay in the meeting record, keep their
normalization history and their review-inbox visibility, and are never presented as
published prose. The page's input hash still identifies the exact evidence input that
produced its content. [Issue 98](https://github.com/RicoTrevisan/brussels-wtf/issues/98)
records the policy change; [ADR 0005](../adr/0005-publish-only-votable-points.md) records
the decision.

An item that asserts a terminal decision outcome or a decision procedural state stays in
the publishable set even when its decision record is missing, so the gate reports
`unsupported_publication_state` and `missing_decision_claim` instead of dropping the item.
Only items that assert nothing publishable are excluded. A meeting whose publishable set is
empty still fails closed with `missing_item`. Every included item keeps all existing gate
checks: official evidence, claim kind, decision outcome, and procedural state. A claim-less
non-votable item that is added later never makes published content stale, because it is
outside the projection and cannot change the page.

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

- `missing_item`
- `missing_claim`
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

Coverage generation is selected independently of extraction and normalization. `COVERAGE_PROCESSOR=recorded` (the default) uses `RecordedCorpusCoverage` for the sealed historic and September selections. Those contracts match the complete source-backed publication input; source drift fails closed instead of receiving stale prose. `COVERAGE_PROCESSOR=opencode` selects the network-backed provider described below. Ordinary tests use controlled HTTP responses and make no paid or nondeterministic calls. Selecting OpenCode does not replace the recorded normalizer or make arbitrary new PDFs supported.


## Runtime generation controls

The application reads these variables when the release starts:

- `COVERAGE_GENERATION_MODE`: `disabled`, `recorded`, or `paid`. The current default is `recorded` so the hash-pinned Ixelles contract remains available. Invalid values stop startup.
- `BACKFILL_GENERATION_ENABLED`: strict `true` or `false`, default `false`.
- `COVERAGE_BACKFILL_MAX_BATCH_SIZE`: positive meeting count, default `10`.
- `COVERAGE_MONTHLY_BUDGET_CENTS`: required positive integer only in `paid` mode. It is rejected in the other modes.

`disabled` still permits polling, retrieval, extraction, OCR, and normalization. Coverage jobs finish without calling processor metadata or a provider, pages remain private, and no publication review case is opened merely because generation is off.

`recorded` permits only a processor that declares recorded billing and no network access. Recorded runs reserve no money. `paid` permits only a network-backed processor and requires the monthly budget. OpenCode always uses `paid` mode. Paid mode with the recorded processor, or recorded mode with OpenCode, fails startup.

`OPENCODE_API_KEY` is the credential for `COVERAGE_PROCESSOR=opencode`. Paid mode rejects a missing or malformed key without echoing it. Disabled mode permits stopping generation without a key. Store the production value as a Coolify secret; do not put resolved credentials in files, logs, commands, issues, or commits. Runtime selection applies to development and production; ordinary tests ignore these operator environment settings.

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

## OpenCode inference

Work is tracked in [issue 95](https://github.com/ricotrevisan/brussels-wtf/issues/95). OpenCode Zen replaced the earlier OpenRouter adapter, which was never activated in production. Git history keeps the OpenRouter implementation and its 2026-09-17 checkpoint.

The ordered chain is pinned in code. Both models use Zen's OpenAI-compatible Chat Completions endpoint and have zero-retention, no-training providers according to Zen's privacy notes. Prices are Zen's published USD list prices per million input/output tokens, checked on 2026-10-17:

1. `qwen3.8-max` — strong primary, $2.00/$6.00.
2. `deepseek-v4.1-flash` — cheap, fast paid fallback from a different upstream, $0.30/$1.20.

There is no free stage. Zen's free models answered `403 FreeTierError` ("can only be used from within OpenCode") for this key, and imitating the OpenCode client would breach that restriction. These are price and policy observations, not a quality benchmark or latency guarantee.

Zen has no server-side fallback, so the adapter runs the chain itself. Each stage is a separate request naming one model. The primary has a 45-second limit. HTTP 408, 429, 5xx, a timeout, or a transport failure can advance once to the fallback, which gets the remainder of the 90-second wall deadline. A 429 whose message says the account budget is exceeded does not advance, because every model draws on the same Zen budget. Neither do 402 (no credit), 401/403 (credential or policy), other 4xx, or a successful but invalid answer. Req does not retry or follow redirects. Existing publication jobs keep their bounded retry policy.

Each request caps input at 64 KiB, encoded request at 128 KiB, response at 256 KiB, output at 8,192 tokens, connect at 10 seconds and receive at 60 seconds. Oversized inputs are rejected rather than truncated. Requests ask for `response_format: json_object` at temperature 0 with no tools.

Zen responses carry token counts but no documented per-request cost. The adapter prices each successful stage as `prompt_tokens × input price + completion_tokens × output price` at list price, rounded **up** to cents. Cached-input discounts are ignored, so the recorded cost is an upper bound. A stage without token counts (HTTP error, timeout, cancellation) has unknown cost. If any attempted stage is unknown, the operation's cost stays unknown and the existing reconciliation contract charges the full reservation.

Every operation reserves **38 cents** before network access. That covers both stages at list price, counting every request byte as an input token plus framing margin and all 8,192 output tokens: 32 cents for Qwen and 6 for DeepSeek. Typical two-item calls cost about a cent, but an operation that falls back is charged 38 cents in the ledger. Model or price changes need a versioned code change, not an environment override.

Each run records the model it requested. That name is the provenance, because a Zen request addresses exactly one model. Zen's own `model` label and response id are retained only as bounded safe strings. Only the publication-input projection or canonical translation text is sent. Requests carry no archive access, tools, browsing, credentials, reviewer notes or suggestion bodies. Exact input/output key validation rejects unexpected fields. A schema and valid claim references do not independently prove that every generated sentence is entailed by its evidence. Real-source language and faithfulness checks are required before scaling.

As defence in depth, give the Zen service account its own monthly budget in the OpenCode Console (**Keys › Set Service Account Budget**) at or below `COVERAGE_MONTHLY_BUDGET_CENTS`. Turn off Console auto-reload for that workspace, or account for it, because auto-reload can charge past the monthly limit.

### Development

The committed `.env.opencode.dev` contains only the 1Password reference `op://Dev/Opencode/brussels-wtf`, not its value. It explicitly opts into OpenCode with a **$1.50/month development ceiling**, enough for three operations at their full reservation, and backfill generation off:

```bash
op run --env-file=.env.opencode.dev -- mix phx.server
```

Use the normal isolated test database for contract checks. Ordinary tests never call OpenCode. Never point these tests at production storage. The opt-in check makes at most three budget-reserved operations (up to six HTTP requests across their bounded stages) using the two already published Ixelles 269 proposal interpretations. It checks structured output, not a new PDF normalizer or a full semantic benchmark, and never publishes:

```bash
op run --env-file=.env.opencode.dev -- env ERL_FLAGS='+S 4:4' \
  MIX_TEST_PARTITION=_live mix test --include external test/contracts/opencode_live_test.exs
```

It prints only sanitized model/usage/status receipts. Test-database reservations roll back; actual Zen charges do not. Do not repeatedly run it to bypass a real spending limit.

### Production activation

This implementation is not evidence of a deployment or a model-quality acceptance. No production credential or monthly budget exists yet. Before activation, pass normal release checks and a bounded real-source FR/NL/EN check, then configure the reviewed release in Coolify:

- `COVERAGE_PROCESSOR=opencode`
- `OPENCODE_API_KEY`: a production service-account key with **Inference only** permission, stored as a Coolify secret, never the dev key
- `COVERAGE_GENERATION_MODE=paid`
- `COVERAGE_MONTHLY_BUDGET_CENTS`: the operator-approved positive USD-cent ceiling; **no production default**
- `BACKFILL_GENERATION_ENABLED=false`

Inspect queued publication work before switching modes. Provider activation does not authorize replaying a historical backlog or publishing unsupported new sources. Keep the existing recorded normalizer, evidence gates and all-locale publication transaction intact. Disable generation with `COVERAGE_GENERATION_MODE=disabled` and `BACKFILL_GENERATION_ENABLED=false`, remove `COVERAGE_MONTHLY_BUDGET_CENTS` (it is valid only in paid mode), and restart. Returning to recorded mode also requires `COVERAGE_PROCESSOR=recorded` and removal of the paid-only budget setting. Prior public revisions remain preserved.

Official references: [models, prices and privacy](https://opencode.ai/docs/zen/), [inference API](https://opencode.ai/v2/docs/console/api/inference/), [budgets](https://opencode.ai/v2/docs/console/budgets/), [billing and HTTP 402](https://opencode.ai/v2/docs/console/billing/), [service-account keys](https://opencode.ai/v2/docs/console/api/).

### Implementation checkpoint — 2026-10-17

The dev key authenticated against `GET /inference/v1/models`, which listed both chain models. Every paid model returned HTTP 402 "Insufficient account funds" because the dev workspace has no credit. The opt-in live check made one request, received 402, did not advance to the fallback, and recorded no tokens or cost. No FR/NL/EN generation has succeeded through OpenCode yet. No production configuration, publication or historical replay changed.
