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

Processor failures retain one coverage-run record per execution. Failures a retry cannot change (`input_too_large`, `invalid_publication_input`, `invalid_canonical_output`, `invalid_generation_output`, `incomplete_generation`, `unsupported_locale`) open a deduplicated high-urgency publication review case on the first attempt and are not retried. Oban retries other failures up to its bounded `max_attempts`; the terminal attempt opens the case. Diagnostics contain durable identifiers and safe classifications, never provider prompts, credentials, private object keys, or response bodies.

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

Work is tracked in [Add budgeted OpenRouter coverage with ordered model fallbacks](https://github.com/ricotrevisan/brussels-wtf/issues/95) and [Generate paid coverage in item batches](https://github.com/ricotrevisan/brussels-wtf/issues/138).

The ordered model stages are pinned in code. Prices are the OpenRouter catalog on 2026-10-18 and the per-stage `provider.max_price` caps (USD per million prompt/completion tokens):

1. `deepseek/deepseek-v4.1-flash`: Rico's primary. Listed at $0.065/$0.144 (OpenInference), capped at $0.10/$0.30, which also admits Decart ($0.09/$0.18) and Sail Research ($0.09/$0.30).
2. `deepseek/deepseek-v4-flash-0731`: same model family on a different provider set (OpenInference, Baidu, DeepInfra, Sail Research). Capped at $0.06/$0.18. This is the model that produced the September dev acceptance.
3. `google/gemini-2.5-flash-lite`: a different vendor on Google's own infrastructure, so a DeepSeek-wide outage still has a route. Capped at $0.10/$0.40.

`stealth/union-alpha` is no longer listed and was removed. The free `google/gemma-4-31b-it:free` stage was also dropped. It never produced a successful generation (HTTP 504 in every September dev call and HTTP 429 in production on 2026-09-19), and it spent up to 20 seconds of each deadline before any paid stage could run. All three stages were checked live on 2026-10-18 with the exact request shape below. These are price and routing observations, not quality benchmarks.

### Item batches

A meeting is generated in bounded item batches inside one coverage operation. Canonical French, Dutch and English each still produce exactly one coverage run over the full publication input, so the gate's run chain, the per-operation budget reservation and the atomic FR/NL/EN publication are unchanged.

- Items are packed in input order: at most 8 items and 20 KiB of encoded items per French batch, and at most 8 items and 12 KiB of canonical items per translation batch. One item above the 64 KiB request input cap, or more than 24 batches, fails closed as `input_too_large` without a network call. Items are never truncated.
- Each French batch uses the existing bundle contract over its own items. For a meeting with more than one batch, one extra page call writes the page title and summary from the validated batch titles and summaries; page `claim_refs` are then set to every claim key. Each translation batch carries the canonical page and its own items; the first batch's translated page is used.
- The assembled bundle is validated again against the full input. Any failed batch fails the whole operation; nothing is assembled or published. After a failure no new batch starts; batches already in flight finish so their cost is recorded.
- Up to four batch calls run concurrently. Each call tries the stages in order inside a 240-second wall deadline (120 seconds per stage).

The limits come from measurement on the real Ixelles 266 (33 items, 43.5 KB, 14,793 input tokens) and 270 (72 items, 116 KB) publication inputs. French output was 0.2–0.3 tokens per input byte (2,823 tokens for 8 typical items; 4,499 for the 7 largest). Dutch output was 0.4 tokens per canonical byte (5,759 tokens for 8 items). Both batch caps keep the expected output under a third of the 16,384-token cap. In the 2026-10-18 dev smoke on meeting 270, the largest batch output was 3,743 tokens.

### Requests

Every request sends `reasoning.enabled=false`, `temperature: 0`, `provider.require_parameters`, `provider.data_collection: "deny"`, `provider.sort: "throughput"` and a strict `json_schema` response format. The schema pins the exact keys, item keys, variant fields and allowed claim references for that batch. On 2026-10-18 the plain `json_object` format let the model add a `"type"` key, which the exact-key contract rejected. The lowest-price primary endpoint generated about 26 tokens/s against about 113 tokens/s on Decart, and full batches timed out at 90 seconds. Throughput ordering stays inside the hard price caps.

A retryable provider or transport failure (HTTP 408, 429, 5xx, wall timeout, or a structured routing 404 with a recognized no-compatible-endpoints message) advances that batch to the next stage. Arbitrary 404s, authentication or payment failures, and successful but invalid content do not advance. Req does not retry or follow redirects. Each request caps encoded input at 64 KiB, the request at 128 KiB, the response at 256 KiB, and output at 16,384 tokens (2,048 for the page call). The connect timeout is 10 seconds. Keepalive bytes cannot prolong the deadline; a cancelled request keeps its cost uncertain.

### Cost

Before network access, an operation reserves the sum, over every planned batch call (plus the page call) and every stage, of each wire byte counted as a token at the stage's prompt cap plus its full output cap, rounded up once to cents. Known stage costs are summed in micro-USD and the operation is rounded **up** once to cents. A stage without a provider-reported cost (for example a timeout) is charged at its own upper bound, so the ledger never undercounts and never exceeds the reservation. Each run's usage keeps a per-call receipt: batch, requested and actual model, provider name, status, tokens, micro-USD cost and duration. Model pricing or caps require a versioned code change, not an environment override.

Requests use `data_collection: "deny"`. This is **not** a zero-retention promise. Do not relax privacy settings to force a model. Each response must name the requested stage model, which is retained in immutable run provenance; the run names one model only when every accepted call used it, otherwise the planned chain. Only the publication-input projection, validated canonical batch text or canonical translation text is sent; no archive access, tools, browsing, credentials, reviewer notes or suggestion bodies. A schema and valid claim references do not independently prove every generated sentence is entailed by its evidence; real-source language/faithfulness checks are required before scaling.

### Development

The committed `.env.openrouter.dev` contains only the 1Password reference `op://Dev/openrouter/brussels-wtf-dev`, not its value. It explicitly opts into OpenRouter with a **$1/month development ceiling** and backfill generation off:

```bash
op run --env-file=.env.openrouter.dev -- mix phx.server
```

Use the normal isolated test database for contract checks. Ordinary tests never call OpenRouter. Never point these tests at production storage. The opt-in check makes at most three budget-reserved operations (one batch each, up to nine HTTP requests across their bounded stages) using the two already published Ixelles 269 proposal interpretations. It checks structured output, not a new PDF normalizer or a full semantic benchmark, and never publishes:

```bash
op run --env-file=.env.openrouter.dev -- env ERL_FLAGS='+S 4:4' \
  MIX_TEST_PARTITION=_live mix test --include external test/contracts/openrouter_live_test.exs
```

It prints only sanitized model/usage/status receipts. Test-database reservations roll back; actual OpenRouter charges do not. Do not repeatedly run it to bypass a real spending limit.

The batched check runs one FR, one NL and one EN operation over a real multi-batch meeting. Real publication inputs are not committed (this repository is public). Export one to a private local file with a read-only call, then point the test at it. It writes the generated bundles next to the input for review and never publishes:

```bash
mkdir -m 700 -p /tmp/coverage-smoke
# Read-only: prints one meeting's publication input. Run inside the app container.
bin/brussels_wtf rpc 'IO.puts(Jason.encode!(BrusselsWtf.Council.Publication.generation_input("<meeting-uuid>")))' \
  > /tmp/coverage-smoke/input.json
op run --env-file=.env.openrouter.dev -- env ERL_FLAGS='+S 4:4' MIX_TEST_PARTITION=_live \
  OPENROUTER_LIVE_INPUT=/tmp/coverage-smoke/input.json \
  mix test --include external test/contracts/openrouter_batched_live_test.exs
```

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

### Batched dev smoke — 2026-10-18

The real adapter generated FR/NL/EN for the Ixelles 270 publication input (72 items, 116 KB): the meeting whose production runs failed with `input_too_large`. Each locale used 9 batches, and FR also made the page call. Every call was served by `deepseek/deepseek-v4.1-flash` (Decart or Sail Research) with no fallback, timeout or invalid output. Wall time was 89 s for FR, 96 s for NL and 65 s for EN. Actual provider cost was $0.0115 + $0.0117 + $0.0102 = $0.0334, and the ledger charged 2 cents per operation. All bundles passed the generation contract; nothing was published. An earlier run with `json_object` output and price-first routing failed NL validation (the extra `"type"` key) and had three 90-second timeouts; that run led to the strict schema and throughput ordering above. No production configuration, publication or regeneration was performed.
