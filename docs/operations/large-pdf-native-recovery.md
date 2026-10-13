# Native-only large PDF recovery

This is an extraction-only first slice, not an OCR recovery or publication release.
It does not authorize production requests, backfills, polling changes, queue pauses,
or downstream release. No review UI route is added.

## Domain boundary

`BrusselsWtf.Ingestion.LargePdfRecovery.request(entries, note, actor: reviewer)`
accepts an explicit allowlist of one to five entries. Each entry contains exactly
`case_id`, `source_version_id`, and lowercase raw `sha256`. Case and version IDs
must be nonduplicate; every hash must match the retained immutable version.
An invalid member rolls the entire request back, including its audits and jobs.
No processor, configuration, run ID, limit, or hold override is accepted.

Each request invokes the reviewer-authorized Ash action
`BrusselsWtf.Review.extract_large_native/3` on the case. It requires a stored,
open extraction deferral with generation `large-source-acquisition-v1`, matching
case/version/source-record lineage, and a `supporting_document` PDF whose positive
size exceeds the ordinary processing cap and is at most 160 MiB. Unsupported
cases, ordinary-size documents, declarations, and other roles are excluded.
The existing ordinary Retry remains blocked for oversized files.

The action records an append-only `retry` audit with effect
`processing_generation`, disposition `retry_requested`, and explicit
`operation=extract_large_native` details. It derives provenance from the deployed
file processor, not reviewer input, then creates the immutable
`review:<audit-action-id>` processing generation and one `ExtractLargeSource` job
on `extract`, with three maximum attempts.

## Execution and retained hold

Every recovery run permanently records `inputs.extraction_only=true`, the raw
hash, operation, audit action, and case identity. Execution checks that audit and
lineage and fails closed on queued processor/configuration drift. A database row
lock serializes concurrent executions; database identities, not Oban uniqueness,
remain authoritative. Only this worker's transaction overrides the 15-second Repo
checkout default. Lock acquisition itself is limited to 15 seconds; a busy replay
returns the sanitized retry result `{:error, :recovery_unavailable}` rather than
starting another extraction. No Repo-wide production limit changes.

The finite transaction checkout budget is 980,000 ms, derived as follows:

- Lock acquisition: 15,000 ms.
- Deployed native provenance probes: a shared 5,000 ms hard task envelope.
- Raw fetch: 60,000 ms, and native extraction: 120,000 ms.
- Archive store: a 750,000 ms hard task envelope, including hashing and final
  byte verification. The collision path can perform four requests (PUT, existing
  GET, metadata HEAD, final verification GET). The current S3 request policy allows
  three 60-second receives and 500/1,000 ms backoffs for each request:
  `4 * (3 * 60,000 + 1,500) = 726,000 ms`; 24,000 ms remains for local file IO.
  Socket receive limits alone do **not** bound trickle bodies, connection waits,
  or runtime request overrides, so the task envelope is authoritative.
- Database persistence and cleanup reserve: 30,000 ms. Checkout expiry rolls back
  the whole generation; it never creates a second transaction to accept stale IO.

The combined raw/native/store task has a 930,000 ms absolute deadline. The lock
owner checks its original checked-out connection with a one-second `SELECT 1`
heartbeat while waiting and immediately before accepting IO results. A failed
heartbeat cancels the linked Elixir task, removes its workspace, and returns only
`{:error, :recovery_unavailable}`; exceptions/changesets/endpoints are not returned
or logged by this integration. An interrupted generation remains queued with no
committed attempt/artifact, so retry keeps its audit and generation identity.
Completed replay only performs its bounded 60-second file verification.

### Live process-tree cancellation / remaining release gate

The connection-loss and worker-kill DB regressions still use a valid file
processor stub; they prove rollback, not native reaping. The independent imported
release-image contract now exercises real `System.cmd` Task death and clean-VM
SIGKILL through `FileProcessor.native/4`. It observes an actual `pdftotext` exec,
then SIGSTOPs that process to make live cancellation deterministic. A separate
wrapper seam exercises closed stdout/stderr and an escaped `setsid()` descendant.
Private receipts record wrapper/root/descendant PIDs, `/proc` start/state data,
monotonic cancellation/absence timestamps, source checksum, and container inspect.
Assertions require every recorded `/proc/<pid>` to disappear, not just an exit
status. The unprivileged outer test subreaper reaps an orphaned wrapper; production
still needs its OS parent/init to reap that wrapper after VM death. Native
children are killed and reaped by the wrapper itself.

`FileProcessor` always passes the fixed `--caller-stdin` liveness protocol.
The wrapper requires fd 0 to be a FIFO, rejects pre-existing EOF/unexpected input
before native spawn, and monitors readability throughout execution, including
when both native output pipes have closed. EOF or any unexpected byte cancels
with numeric limit 6, kills the original process group, and kills/reaps every
subreaper-adopted generation, including escaped sessions. Native stdin remains
`DEVNULL`; no source data is sent through the liveness pipe. Healthy callers keep
the pipe open, but its presence never delays a completed native root. The direct
Python test API leaves this watcher disabled unless explicitly requested.

The watcher shares the 10 ms CPU watchdog interval. Under the tested one-CPU,
1-GiB/no-swap, nofile1024, PID-capped, capability-dropped offline envelope, the
contract requires disappearance within 500 ms; this is a scheduling/polling test
tolerance, **not** a zero-overlap or instantaneous-cleanup guarantee. A retry
admitted immediately after lock loss can still overlap that short cancellation
interval. Task/VM death cannot receive the numeric cancellation result and cannot
run workspace cleanup; abandoned files remain caller-owned. No DB/queue policy,
production runtime, host cgroup rules, or public native/OCR API is changed.

Reproduce without application/DB startup:

```sh
python3 test/support/pdf_contract/run_file_cancellation_contract.py
mise exec -- python3 test/support/pdf_contract/run_file_ocr_contract.py
```

These contracts compile mounted current modules into imported image
`sha256:3df4c19c385e4e27b667d65d3a2c9356c41acc08c7716baa05655fb30449882c`;
they do **not** prove newly built release packaging. The synthetic cancellation
PDF is created privately and permission-read-only, with checksum verified after
cancellation; no retained original is modified. The companion native/OCR suite
checks successful extraction/Quality and unchanged CPU, memory, byte/inode scratch
limits with dedicated 512-MiB OCR tmpfs. Native/OCR v2 provenance already binds
implementation and wrapper bytes, so this change alters both config hashes and
queued drift remains fail-closed. New release packaging, crash workspace cleanup,
and strict cross-failure zero-overlap serialization remain separate release gates.

The worker fetches the retained archive snapshot through `Archive.fetch_file/5`
with explicit 160 MiB, 60-second total-read, and 15-second receive bounds, into a
private 0700 workspace. It calls the file processor with the unmodified native
limits (500 pages, 64 MiB native text, 90 CPU seconds, 120-second wall time,
1 GiB subprocess address space). Text is stored with `Archive.store_file/2`;
neither the raw PDF nor extracted text is loaded wholesale by this integration.
Workspaces are removed on success and handled failure. VM death cannot run cleanup.

The original page-level quality decision is retained exactly. Empty or inconsistent
page coverage cannot produce an accepted artifact. Rejected native text is still
retained privately as a `native-text` artifact; the deferral remains open and no
OCR is queued. Only all-page native acceptance resolves the original case through
completion of its audited generation. Run summaries contain counts and hashes,
not source text or scratch paths. Artifact links preserve each generation even
when identical content-addressed bytes are shared across source origins.

Completed replays verify the linked text's lineage and archived hash/byte count,
skip native processing, and do not rewrite the run or its artifacts. Verification
failure opens a generation-linked review case without rewriting completed outputs.
Deterministic corruption/resource failures are terminal; transport/executable
failures receive at most three attempts. Exceptions are sanitized before recording.

Acceptance does **not** remove the persisted extraction-only hold. Ordinary
`Pipeline.extract(run_id)`, `retry_extraction`, `ocr`, and direct `normalize`
return `{:error, :extraction_only}` before ordinary processing or reconciliation.
There is no normalization, publication, identity wakeup, OCR, or release action
in recovery completion or replay. Downstream release requires a separate future
audited design; reviewers cannot forge a flag to enable it.

## Focused tests

After integrating the archive-file-read foundation and file processor:

```sh
PGPORT=55441 MIX_ENV=test mix test test/brussels_wtf/ingestion/large_pdf_recovery_test.exs
PGPORT=55441 MIX_ENV=test mix ash.codegen --check
```

Use only the disposable PostgreSQL test database and test credentials. The real
concurrent-connection test uses scoped committed fixtures and verifies that removing
the row lock permits a second native invocation. Its cleanup transaction requires
a disposable superuser: the existing suggestion-case DELETE trigger returns NULL
for non-suggestion cases, so cleanup temporarily disables triggers for that session
and deletes only its own fixture IDs. Processing assertions run with all triggers
and constraints enabled. This is not a production permission requirement or a
production database repair.

Production recovery, user-facing request wiring, and downstream release remain
separately authorized work. The separate authenticated, held page-selective OCR
implementation is documented in `large-pdf-ocr-recovery.md`; this native action
still does not automatically enqueue it.
