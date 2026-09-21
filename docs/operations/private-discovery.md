# Private municipal discovery on lab

Work: [Discover private municipal mentions with a resumable lab Codex worker](https://github.com/ricotrevisan/brussels-wtf/issues/102).
Contract: [private discovery](../specs/private-discovery.md).

This is mention discovery, not identity resolution or publication. It creates
unresolved `Mention` records only. It does not create people, companies, verified
roles, relationships, coverage or notifications. A successful batch is not a
complete inventory of a commune and not evidence that a relationship exists.

## Operator flow

After deploying the reviewed release and migrations, run
`priv/ops/private_discovery.exs` through the existing authenticated release RPC.
Default invocation is read-only, printing safe candidate metadata. Pass bindings
with `Code.eval_string(File.read!(Application.app_dir(:brussels_wtf,
"priv/ops/private_discovery.exs")), bindings)`:

```elixir
[operation: :candidates, commune: "ixelles", limit: 10]
[operation: :preview, run_ids: [actual_extraction_run_id], max_jobs: 8]
[operation: :enqueue, run_ids: [actual_extraction_run_id], max_jobs: 8]
[operation: :status, batch_id: returned_batch_id]
[operation: :pause]
[operation: :resume]
```

Candidates are succeeded native/OCR runs, not a guarantee of eligibility. Use the
returned `next_cursor` to page candidates, including an empty filtered page.
Preview rechecks authoritative artifact links, actual archived bytes, municipal
origin, unambiguous meeting context, four-commune scope and dates >= 2024-01-01.
It reports excluded lines, chunk counts, `has_more` and `next_chunk_offset`.
The wrapper never prints prepared source text. Do not log `Discovery.preview/2`
in full when using the domain directly.

A batch accepts at most 20 explicit runs and a mandatory 1–100 job cap. Each run
selects up to eight chunks (60 lines/12 KB each). Continue that run with the
reported `chunk_offset`; chunk identities are absolute and overlap is idempotent.
Finish one run's pages before moving the candidate cursor if complete coverage is
wanted. Do not confuse a processing-run ID with a source-version or artifact ID.

All private-session material after a detected marker is omitted. Sensitive
paragraphs and oversized lines are excluded before transfer. These conservative
FR/NL heuristics are **not a guarantee of complete PII detection**; measure omissions
and inspect representative source layouts before expanding. Mandate declarations,
Gazette acts, recordings and unrecognized supporting-document roles are excluded.
This discovery does not activate those sources or change their access rules.

## Automatic admission (issue #105)

**Disabled by default.** Deploying the code or configuring the machine token does
not enable automatic admission. After migrations, inspect safe state via the same
authenticated release RPC wrapper:

```elixir
[operation: :sweep_status]
[operation: :enable_sweep] # explicit operator authorization; initial limits below
[operation: :pause]        # global hold, including an empty queue
[operation: :resume]       # clears hold; preserves opt-in, cursors, attempts and budget
```

Direct domain equivalents require `actor: %BrusselsWtf.Review.Actor{...}` with a
nonempty reviewer ID: `Discovery.enable_sweep/1`, `Discovery.sweep_status/1`,
`Discovery.pause/1`, `Discovery.resume/1`. The RPC wrapper derives that actor
from review configuration; never expose it to an unauthenticated caller.
`enable_sweep` **does not clear an existing manual or quota hold**. Resume does
not enable a never-enabled sweep. Pause invalidates leases as before; stop the
lab consumer first when possible.

The maintenance cron ticks once per minute. Hard ceilings (lower values may be
persisted through explicit enable options) are four examined runs per tick,
one per available commune; eight **new** jobs per tick; and 64 unfinished jobs
(queued + leased + paused) globally. The initial admission allowance is **12 new
jobs per UTC day**, adjustable only explicitly with `daily_jobs: 1..500`:

```elixir
[operation: :enable_sweep, max_runs: 4, max_jobs: 8,
 max_unfinished: 64, daily_jobs: 12]
```

Unknown domain options and out-of-range limits are rejected. Omitted limits
retain their stored values. Re-enabling, pausing, resuming or restarting does not
reset the current day's spending. UTC rollover renews the allowance, not a quota
hold. The allowance counts admitted jobs, **not tokens or inference attempts**;
the unchanged worker can retry each job up to three times. These are conservative
rollout limits, not measured capacity or a subscription-token budget. Measure
actual usage, latency, omissions and terminal failures before raising them.

Explicit `enqueue` remains available without sweep opt-in for compatibility, but
shares the global hold, UTC admission allowance and unfinished-job ceiling. It
cannot override quota holds. Existing input identities cost no new admission;
failed jobs are not automatically re-executed. One original lab Codex consumer
remains the only inference consumer. There is no new paid fallback, polling,
normalization or coverage generation action.

Per-commune run-ID cursors cycle repeatedly, with rotating first-commune priority.
This revisits older queued runs that later succeed and previously excluded runs
whose context is corrected. A durable per-run absolute chunk offset allows all
chunks to be admitted across bounded ticks; neither the old 20-candidate window
nor eight-chunk window is a permanent truncation. Archive reads occur outside
the serialization transaction; a concurrent hold/admission invalidates the
prepared cursor before jobs can commit. Next tick retries from committed state.

`sweep_status` returns safe control state, counts, 100 run progress rows, recent
operation receipts and 100 terminal failures. Page each independently with the
returned `next_cursor` → `cursor`, `failure_cursor` and `event_cursor`. Counts
cover all retained discovery jobs, including explicit batches. `examined` counts
unique sweep runs; `examinations` includes repeated visits; `eligible`, `excluded`
and `fully_admitted` describe runs. `completed` and `failed` describe **jobs**, not
complete documents. Fully admitted is not equivalent to successfully analyzed.
`mention_occurrences` counts deduplicated retained discovery evidence;
`unique_mention_names` counts distinct exact `(kind, text)` values and
`repeated_mention_names` is the remainder—none is a resolved-person count.

Run exclusions include uncertain meeting context, ineligible date, missing
linked authoritative text, unverified source, no eligible public lines and
preparation failure. Exclusion measurements, cursor progress, control audits,
per-tick new/existing counts, failure receipts and terminal reasons live in Ash
resources independently of Oban pruning. No source text is included in the
operator report. Inspect a failed job through the private batch status rather
than deleting it or blindly resetting attempts.

Local acceptance uses an isolated `_sweep105` database partition, real Ash and
archive/input fixtures, including >20 runs, >8 chunks, all four communes,
concurrent pause during archive I/O and repeated/restarted ticks. No production
activation, model call, measured throughput or recall is claimed by this change.

## Machine access

Generate a random dedicated token into an owner-only file on lab; configure only
its lowercase SHA-256 as `DISCOVERY_TOKEN_SHA256` on the app. Never put the raw
token in Coolify, Git, commands, logs, URLs or the Codex container. No configured
digest means the endpoints are disabled. Rotation changes the app digest and the
lab token file. The token permits only claim/result/failure operations, not
arbitrary archive access, operator actions or publication.

The app has one global active lease, a 15-minute expiry and three attempts per
job. Expired leases are recovered when another claim arrives. Retry delays are
bounded. Identical success and failure retries are idempotent. A quota response
pauses unfinished jobs globally; the operator explicitly resumes after the
subscription resets. Pause invalidates active leases, so stop the worker first
when possible. Completed evidence is retained.

## Isolated runner

Build on lab with a minimal context:

```sh
tar cf - Dockerfile.discovery-worker scripts/discovery_worker.py | \
  docker build -f Dockerfile.discovery-worker -t discovery-codex:0.155.0 -
```

The wrapper uses supported `codex exec`, ChatGPT subscription authentication,
structured JSON output and the explicitly selected model. It starts a disposable
nonroot, read-only, one-CPU/1-GiB container per job. Only the prepared input, schema
and narrowed subscription authentication enter it. Shell tools, browsing, MCP,
user config, hooks and repository instructions are disabled. No app/DB credentials,
machine token, repository, host home or Docker socket are mounted. Model inference
still happens at OpenAI and consumes the user's shared Codex allowance.

Docker bridge networking is not an egress firewall. Apply a dedicated bridge
policy blocking host/private-network access before treating the container as
network-isolated. Container filesystem isolation does not justify claiming a
network isolation guarantee. Subscription token refreshes are deliberately not
written back from the disposable container; use `codex login status` and renew
through normal login if needed, never fall back silently to API-key billing.

Run a bounded first batch:

```sh
python3 scripts/discovery_worker.py \
  --base-url https://brussels.wtf \
  --token-file "$HOME/.config/brussels-discovery/token" \
  --auth-file "$HOME/.codex/auth.json" \
  --state-dir "$HOME/.local/state/brussels-discovery" \
  --model gpt-5.6-sol --max-jobs 4
```

Prefer a reviewed image digest with `--image` for an installed service. One local
file lock and the server lease prevent parallel inference. Default execution
limit is five minutes. Output and HTTP bodies are capped. The mode-0600 durable
spool retains results until acknowledged, so a transport outage does not repeat
inference. Restarting retries the pending submission before claiming more work.
A rejected/stale result stops for reconciliation; do not delete evidence and
blindly rerun. Inspect private spool locally, never print it into shared logs.
Acknowledged results and temporary per-job input/auth files are removed. Keep
pending spool only until reconciled, then remove it; it is not a second archive.
A killed process can leave a private `run-*` directory: stop the service, confirm
no matching container is alive, and remove only that task's abandoned directory.

Worker exits: 75 transient transport, 77 auth rejected, 1 fail-closed/configuration.
No OpenRouter calls are made by this slice; its capped key is unchanged. Automated
paid fallback needs a separate adapter using the same input/evidence rules and a
compatible spending ledger.

## Verification and honest acceptance

```sh
ERL_FLAGS='+S 4:4' MIX_TEST_PARTITION=_sweep105 \
  mise exec elixir@1.19.5-otp-28 erlang@28.1 -- \
  mix test test/brussels_wtf/private_discovery_test.exs
ERL_FLAGS='+S 4:4' mise exec elixir@1.19.5-otp-28 erlang@28.1 -- \
  python3 -m unittest discover -s test/scripts -p test_discovery_worker.py
ERL_FLAGS='+S 4:4' MIX_TEST_PARTITION=_sweep105 \
  mise exec elixir@1.19.5-otp-28 erlang@28.1 -- mix precommit

# Separately authorized model calls only; NOT an ordinary verification step:
DISCOVERY_CODEX_LIVE=1 ERL_FLAGS='+S 4:4' MIX_TEST_PARTITION=_discovery_live \
  timeout 600s mix test test/contracts/discovery_codex_live_test.exs --include external
```

The last command makes at most four actual subscription calls, one per commune,
using hash-pinned bundled PDFs, actual native extraction, isolated test storage,
real Codex and the application's actual HTTP submit/validation path. Ordinary
suite runs make no model calls. Optional `DISCOVERY_CODEX_COMMUNES=ixelles` selects one
commune (plural variable name; comma-separated values select several). For one
call use `DISCOVERY_CODEX_LIVE=1 DISCOVERY_CODEX_COMMUNES=ixelles` with the same
isolated test command above. Tests roll back mentions and never mutate production.

Successful bounded lab runs on 2026-09-20 produced 25 Ixelles, 20 Uccle, 49 Forest
and 19 City of Brussels mentions. These are 113 **occurrences**, not necessarily
113 distinct people/organizations. Receipts span several bounded runs; see the
specification for the real validation defect, regression and exact scope. This
is not a single identical-build full-suite result or a recall/accuracy benchmark.
Production acceptance additionally requires the exact deployed SHA, healthy app,
configured machine auth, actual archived-run IDs, completed batch status and no
new public facts. Do not close the delivery issue on test-only evidence.
