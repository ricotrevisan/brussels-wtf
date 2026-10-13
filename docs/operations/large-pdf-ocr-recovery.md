# Held, page-selective large PDF OCR recovery

This implements private extraction recovery, not publication permission. It adds no
review UI route or release action, does not deploy a worker, and does not authorize
production requests or a backfill. Native evidence and its acceptance stay immutable.

## Authenticated request

`BrusselsWtf.Ingestion.LargePdfOcrRecovery.request(entries, note, actor: reviewer)`
accepts one to five distinct stored source versions/cases. Each entry has exactly:

```elixir
%{case_id: case_id, source_version_id: version_id, sha256: raw_sha256,
  native_run_id: native_run_id, original_pages: [2, 7]}
```

The raw hash must be lowercase SHA-256 and match the immutable version. Pages must
be sorted, unique positive integers, at most 32, and exclusively rejected pages of
that exact successful, audited, extraction-only native generation. The native
quality page sequence, artifact links, source/case lineage and original audit
provenance must agree. Accepted native pages cannot be selected. UUID aliases do
not permit a duplicate document in the same batch. An invalid member rolls back
all requested audits, budgets, page runs and jobs. No caller-supplied processor,
configuration, limit, profile, parent run, or hold override is accepted.

The named reviewer-authorized Ash action is `Review.ocr_large_pages/3`. It appends
a `retry` audit, pins current `ocr_metadata()` name/version/config hash and all tool
versions, and creates `review:<audit-id>` with `operation=ocr_large_pages` and
`extraction_only=true`. Each page has an immutable processing identity
`review:<audit-id>:page:<original-page>`, that same raw input and provenance, and
an explicit parent/page map. One `OcrRecoveryBudget` belongs to the generation.
Only `OcrLargeSource` jobs on `ocr` are enqueued; the initial genuine-failure
allowance is 3. Guard-contention snoozes extend transport attempts without spending it.
Request checkout is bounded to 630,000 ms: at most five processor-contract 120s
metadata probe envelopes, plus 30s for domain persistence. Ordinary 25 MiB
processing limits remain unchanged.

## Quota-backed worker and serialization

Execution requires the actual configured `:ocr` role before processing. The app
role discards without mutating a parent or chunk. The existing role consumes only
`ocr`, at concurrency one **per node**. Across consumer nodes sharing this database,
a dedicated linked Postgrex connection holds transaction advisory key
`1203121079`; it guards the whole fixed workspace operation. Domain writes remain
named Ash actions on Repo, with page/parent/budget row locks and database identities.
The separate guard transaction does not roll back previously committed reservations.
Guard SQL is read-only. Both ownership connections are checked while awaiting IO;
caller death closes the linked guard connection and cancels its linked IO task.
A busy guard snoozes the transport job for 30 seconds, including at its last
failure attempt; it never fails another live owner or spends a page reservation.
The actual Oban engine extends `max_attempts` when snoozing. The worker subtracts
those extensions when counting genuine admission failures, preserving the existing
three-failure allowance rather than exhausting it while waiting for the guard.
The guard connection preserves Repo's Postgrex network options, including IPv6
socket options, TLS settings and connection timeouts, without inheriting its Ecto
pool. Use this mount with only this application database/worker family.

Operator-only setting `:large_pdf_ocr_workspace` is supplied through
`LARGE_PDF_OCR_WORKSPACE`, default `/app/large-pdf-ocr-scratch`. The directory itself,
not a random subdirectory, must be a private 0700 dedicated tmpfs mount with an
enforced capacity at most 512 MiB. Validation precedes archive writes. There is no
free-space admission substitute or persistent-disk checkpoint fallback.
`docker-compose.ocr.yml` declares the 512 MiB, `nosuid,nodev,noexec` mount owned by
65534:65534. A real `id` probe of imported image
`sha256:3df4c19c385e4e27b667d65d3a2c9356c41acc08c7716baa05655fb30449882c`
returned `uid=65534(nobody) gid=65534(nogroup)`. Recheck the actual candidate image
before deployment; this is not proof of a new release's packaging or OS parent/init.

The mount is an exclusively reserved namespace: `recovery-<uuid>-*` and
`ocr-page-<nonce>` are owned scratch, never evidence checkpoints. Admission scans
at most 1024 root entries, 4096 total nodes and depth 8, with a 5s scan deadline;
foreign names or any symlink cause rejection without deleting them. Successful
and handled-failure paths remove only that owned scratch. Crash residue is cleaned
under the execution guard before admission. A dead VM cannot run `after` cleanup.
Native caller-stdin cancellation and subreaper reaping are inherited from the
existing processor contract: its constrained-image 500ms disappearance test is
polling/scheduling tolerance, not zero overlap. The OS parent/init must reap an
orphaned wrapper after VM death. These assumptions remain release gates.

## Finite document accounting

The generation allowance is **90,000 ms native-tool CPU and 120,000 ms processing
wall**, not a new allowance per page/job. `reserve` locks the budget and durably
charges the remaining allowance before invocation. CPU is rounded down to whole
seconds. Execution provenance probes use reduced, accounted limits without changing
pinned default provenance; page options can reduce only CPU/wall. Queued drift
fails before OCR. `FileProcessor.cpu_ms` reads the private invocation ledger before
cleanup and includes every bounded command and version probe, not merely OCRmyPDF.
The worker adds execution-metadata CPU and records the aggregate in chunk/run and
attempt accounting. It never infers spending from stderr. Fixed admission checks,
archive/DB housekeeping and BEAM CPU are not native-tool CPU ledger measurements.

A successful, verified page refunds only the measured unused reservation, in the
same transaction as its immutable checkpoint. Unknown/error spending retains the
entire reservation; death/connection loss cannot refund it. Tokens and database
row locks fence duplicate settlement and claims. There are at most three claims
per page, counting failed reservations. A later explicit audit may authorize a
new finite generation; transport retries never reset an allowance.

Assembly has its own durable, one-per-generation wall reservation from that same
remaining 120s. Native quality verification, streaming assembly and final exact
FileQuality validation share it. Hash-verified completed checkpoints are reused,
not OCRed or repeatedly quality-reinterpreted. Unknown assembly spending also
stays reserved. Archive reads/uploads are separately bounded IO, not processing
wall. Exhaustion preserves completed artifacts, leaves downstream held, and opens
an actionable generation-linked case.

Bounds remain 160 MiB input, 500 original pages, 25 MiB qpdf subset, 64 MiB OCR PDF
per page, 256 KiB page text and 64 MiB full text. Retained page outputs collectively
are capped at 128 MiB; assembled text adds at most 64 MiB (192 MiB new derived
outputs). Scratch is continuously constrained by the kernel mount.

Scoped finite ownership envelopes (not Repo-wide timeout changes):

- Page IO: 60s raw fetch + 120s processing + two 750s verified archive stores =
  1,680,000 ms. Page transaction adds 15s lock acquisition and 30s DB/cleanup:
  1,725,000 ms.
- Checkpoints: at most 64 bounded 60s GETs plus 120s local verification/cleanup
  reserve: 3,960,000 ms.
- Assembly: one native GET + at most 64 checkpoint GETs + at most 120s remaining
  validation + one 750s verified store, plus 45s lock/DB reserve: 4,815,000 ms.
- Worst guard job is checkpoint replay + one page + final assembly: 10,500,000 ms.
  Oban's hard worker timeout adds 30s cleanup reserve: 10,530,000 ms.

The conservative IO envelopes account for slow verified storage/collision retries;
they do not grant additional OCR CPU or processing wall. Unexpected errors are
sanitized; private paths, endpoints, keys and extracted bytes are not diagnostics.

## Immutable checkpoints and complete artifact

Each page retains checksum-verified `ocr-page-text` and `ocr-page-pdf` artifacts,
even on quality rejection, linked to its original-page processing run. Both stores
must verify before the attempt/run/links commit. Resume checks hashes, sizes,
provenance and the exact original map before admitting another page. Shared
content-addressed bytes preserve each generation through artifact links, not by
rewriting an artifact's first-origin annotation.

Assembly requires every selected terminal page, exactly once, plus unchanged
native text for every other original page. It streams a bounded formfeed-complete
text file, assesses it with unchanged FileQuality thresholds, and archives exactly
one final `ocr-text` artifact. Parent output retains an ordered `page_manifest`
covering every original page with native or OCR run/local-page/hash references.
No large composite OCR PDF is archived: page PDFs plus the manifest preserve it.
Missing, duplicate, corrupt or mismatched checkpoints cannot create an accepted
final artifact. Unselected rejected native pages stay rejected. Blank, sparse
and contents pages receive no exemptions. A complete rejected text artifact is
retained honestly and its case stays open; only all-page acceptance resolves the
original deferral. Mechanical acceptance is not semantic/policy approval.

Every parent and chunk retains extraction-only intent forever. Ordinary extraction,
OCR and normalization workers discard held runs even at terminal attempts.
Completion and replay enqueue no normalization, publication or identity work.

## Reproduction and remaining gates

Use only a disposable test database on PGPORT 55441 and an explicitly prepared
private dedicated tmpfs outside the repository; never production SQL or credentials.
With `OCR_TEST_WORKSPACE` set to that mount:

```sh
OCR_TEST_WORKSPACE=/path/to/private-ocr-tmpfs PGHOST=127.0.0.1 PGPORT=55441 MIX_ENV=test mise exec -- mix test test/brussels_wtf/ingestion/large_pdf_ocr_recovery_test.exs test/brussels_wtf/pdf/file_processor_accounting_test.exs
PGHOST=127.0.0.1 PGPORT=55441 MIX_ENV=test mise exec -- mix ash.codegen --check
python3 test/support/pdf_contract/run_ocr_accounting_contract.py
```

Without the explicit quota mount environment, the integration file is visibly
skipped rather than replacing kernel enforcement with a test-only bypass. Its
unboxed probes use exact-ID synthetic fixture cleanup and transaction-local trigger
bypass only in the disposable database. Processing assertions retain constraints
and triggers. It tests long (>15s) independent ownership, live connection loss and
worker death; native reaping itself is the separate real processor contract.

The last command is a **new OCR-only** single synthetic-page accounting contract:
no native suite, no application/DB startup, no network, read-only input, one CPU,
1 GiB/no-swap, uid 65534 and dedicated 512 MiB tmpfs in the imported pinned image.
It emits private receipts outside the repo. It compiles current mounted modules,
not a newly packaged release. The separate native-image fixture suite passed
after explicit approval on 2026-10-13; it is not invoked by this command.
Full-suite, new release packaging, final release/OS
cancellation gates, representative real-source OCR and any production recovery or
publication release remain separately authorized work.
