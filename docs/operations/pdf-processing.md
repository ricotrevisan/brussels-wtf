# PDF extraction and OCR operations

Issue #21 introduces a Poppler-first extraction contract. Every PDF is checked by `pdfinfo` and extracted with `pdftotext` before OCR is considered. Page decisions, executable versions, safe command outcomes, language signals, timings, and configuration hashes are retained on the processing generation. Native text is always archived as a private derived artifact.

## Calibrated quality contract

The representative calibration corpus is in `test/support/pdf_calibration/manifest.json`. It retains attributed public administrative PDFs from Ixelles, Uccle, Forest, and the City of Brussels, with capture hashes, manual page labels, source origins, and a repository-suitability disposition. The separate `test/support/pdf_contract` corpus contains agent-authored CC0 image-only, partial-scan, rotated, encrypted, malformed, and byte/page-limit hazards. The pinned production-image contract is authoritative because developer machines need not contain Poppler or OCR.

The `pdf-extraction-v1` thresholds are explicit in `config/config.exs`:

- at least 40 trimmed characters per page;
- at least 6 words per page;
- alphanumeric/non-space ratio of at least 0.5;
- control-character ratio no greater than 0.01;
- replacement-character ratio no greater than 0.005.

A single rejected page rejects native extraction for the document. Only rejected page numbers are sent to OCRmyPDF with Tesseract `fra+nld` and `--redo-ocr`; accepted pages outside that selected set are retained and are not re-OCRed. OCR PDF/text outputs are archived before the quality decision, so rejected OCR remains private review evidence; normalization still reads only a checksum-verified accepted text artifact.

## Isolation and limits

The same release image has two mutually exclusive roles:

- `PROCESS_ROLE=app`: web, polling, fetching, sealed corpus import, native extraction, normalization, private enrichment, and publication; it cannot consume OCR jobs.
- `PROCESS_ROLE=ocr`: no Phoenix server or cron plugins, and only the `ocr` queue at concurrency 1.

The image startup command validates dependencies before it runs
`/app/bin/ocr_worker`. Use the same image digest as the healthy app; do not
independently rebuild OCR. For the Coolify Compose application, set
`connect_to_docker_network=true` so the worker joins the existing private
PostgreSQL/rustFS destination network. OCR has no public ports; the public app
uses `https://brussels.wtf`.

`/app/bin/ocr_ready` is the image and Compose health probe. It uses a bounded RPC
into the running release and reads the expiring dependency cache plus the actual
local Oban consumer. Only runtime role `ocr` with a fresh successful dependency
check and an unpaused `ocr` queue at limit 1 is ready. Validation still in
progress, dependency failure/staleness, a missing/crashed consumer, or an
unresponsive release fails closed. The probe does not run extraction, enqueue
work, write validation objects, or change queue state. See
[deployment diagnostics](deployment.md#ocr-readiness-and-read-only-diagnostics)
for read-only health, network, image-parity, and queue commands.

Migrations remain owned by the app role. The production image pins Debian Bookworm and contains Poppler 22.12, OCRmyPDF 14.0, Tesseract 5.3, and the `fra`, `nld`, and `osd` data packages. Release validation fails closed when the toolchain or bilingual language data is missing. Automatic transcription is explicitly disabled.

The calibrated defaults are 25 MiB input, 500 pages, 120 seconds wall time, 90 CPU seconds, 1 GiB address space, and one OCRmyPDF job. A 2026-08-19 run of the partial-scan contract in the release image, capped at one CPU and 1 GiB, completed in 8.4 seconds and peaked at about 180 MiB. The defaults provide headroom for representative documents while the separate role, queue concurrency, cgroup limits, `timeout`, and `prlimit` protect the app/database/archive processes. Configure the Coolify OCR container with one CPU and 1 GiB hard memory. Runtime overrides are `PDF_MAX_INPUT_BYTES`, `PDF_MAX_PAGES`, `PDF_OCR_WALL_TIME_MS`, `PDF_OCR_CPU_SECONDS`, and `PDF_OCR_MEMORY_BYTES`.

## Failure and observability

Poor native quality is routing, not a terminal failure. Invalid/malformed input, oversized input, and exhausted CPU/memory/wall limits are classified and converge on one private extraction review case per processing generation. Other executable failures retry at most three times. Reviewer retry appends a generation keyed by its immutable audit action and never mutates raw bytes or prior artifacts, even when the processor/configuration identity is unchanged. Reviewers provide only a note; processor name, executable version, and configuration hash are derived from the deployed processor contract rather than accepted from form input, then verified again at execution. A terminal reviewer retry opens a distinct case keyed to that failed generation. Authenticated case diagnostics include safe run/attempt timing, tool versions, quality, and artifact hashes without archive object keys or source text.

Safe telemetry covers page rejection counts, native/OCR duration, OCR routing, bounded retries, review-case creation, backlog, and oldest OCR queue age. Correlation identifiers include source version, processing run, and review case. Logs exclude object keys, source bytes/text, command output, endpoints, credentials, and private diagnostics.

Run the image contract with:

```sh
docker build --target runner -t brussels-wtf:pdf-contract .
PRODUCTION_IMAGE=brussels-wtf:pdf-contract mix test --include external test/contracts/production_image_pdf_test.exs test/contracts/production_image_ocr_readiness_test.exs
```

## Bounded real-source OCR verification

**Status: procedure only; no fresh production OCR is claimed without a completed
receipt.** Run this separately from readiness and fixture tests, after the final
app/OCR image parity checks pass. An authorized operator selects the source;
this runbook does not authorize a backfill, publication, or a queue-state change.

### 1. Read-only selection and approval

1. Sign in at `https://brussels.wtf/review`. Select **one existing open extraction
   case** for one retained, authoritative council PDF. Record the case UUID,
   commune, exact origin URL, source-version UUID, raw SHA-256 and byte size.
   Use its private source preview; do not fetch a replacement from the origin.
2. In **Diagnostics and processor logs**, record the existing native/OCR run IDs,
   generation keys, status, page count, rejected pages, quality and artifact
   hashes. Require native `accepted=false` with nonempty `rejected_pages`, and
   visually confirm those retained pages genuinely require OCR. Prefer a short
   scan. Require at most 25 MiB and 500 pages; exclude encrypted, unsupported or
   corrupt inputs and inputs used by identity/mandate processors (including
   `mandate_declaration`). If no eligible
   case exists, report **blocked**; do not fabricate a case or force OCR on an
   accepted native document.
3. Save the original private preview in an operator-only directory outside the
   repository. Hash it locally with `sha256sum`; require equality with the stored
   raw SHA-256. Record any existing accepted or failed `native-text`, `ocr-pdf`
   and `ocr-text` artifacts as the before-state. Do not copy source text, private
   object keys, preview tokens or credentials into the receipt.
4. Require no incomplete native/OCR generation already targeting this version.
   Record image IDs and the read-only [queue/health probes](deployment.md#ocr-readiness-and-read-only-diagnostics).
   OCR must already be healthy, idle, unpaused and limit 1, with the existing
   one-CPU/1-GiB container limits. Keep `fra+nld`, one OCRmyPDF job, 120 seconds
   wall time, 90 CPU seconds and the 1-GiB processor address-space cap unchanged.
5. **Check the downstream hold before authorizing Retry.** Successful extraction
   automatically queues normalization. On every app consumer, require an
   already-authorized hold on `normalize` and `publish`: read-only
   `Oban.check_queue(queue: :normalize)` and `Oban.check_queue(queue: :publish)`
   must show `paused: true` and `running: []`. If the hold is absent or uncertain,
   stop and obtain a separate operational decision. `recorded` generation mode
   is not a publication hold. Do not pause, resume, or drain queues as part of
   this procedure; leave the OCR consumer unchanged.

This is the dry run: source selection, archive reads, hashes and inspection only.
There is no `dry_run` parameter on the Retry action. Approve exactly this source,
case and before-state before proceeding.

### 2. Submit one audited retry request

Use **Retry** once on `/review/cases/<case-id>`, with a note identifying incident
`#74`, the source-version UUID/raw hash, the approved bounds and the before-state
run IDs. Keep the authenticated session and normal CSRF protection. The existing
form posts to `/review/cases/<case-id>/actions/retry`; it invokes
`BrusselsWtf.Review.retry_review_case!` with `%{note: note, details: %{}}` and the
authenticated reviewer actor. Do not invent a processor/configuration override,
call a worker directly, insert an Oban job, or change rows through SQL.

Record the new review-action UUID. The action creates a native extraction run
with `generation_key=review:<action-id>`. Only a fresh native rejection routes
one OCR generation, `generation_key=ocr:<new-native-run-id>`, with
`inputs.native_run_id` linking it to that native run. If native extraction now
passes, stop: that result is **not** fresh OCR evidence. Do not force rejection.

One request means one new generation, not a promise of one executable invocation:
`OCRSource` has the existing maximum of three transport attempts. Do not submit
a second Retry. Observe for at most ten minutes; on an error, limit breach,
checksum mismatch, unhealthy consumer or expired observation window, stop the
verification and record the failure/pending state. This does not cancel normal
bounded retries; any cancellation needs a separate, narrowly scoped operator
decision. Never widen limits, drain backlog or force a case/run to complete.

### 3. Verify the archived result and write the receipt

- Reload the case. Use **Diagnostics and processor logs** to identify the new
  OCR run and its attempts, not merely an old artifact row. The read-only API
  `BrusselsWtf.Ingestion.get_processing_run!(ocr_run_id)` exposes its input
  linkage, pages, languages and limits;
  `BrusselsWtf.Ingestion.ProcessingRun.review_context(run)` exposes sanitized
  provenance, status, timings, attempts, quality and linked artifact hashes.
- Require a new executed OCR run with `status=succeeded`, valid start/completion
  times, the expected native-run/source linkage, `fra+nld`, unchanged limits,
  `accepted=true`, and the recorded page-level decisions. Record the deployed
  processor name/version/configuration hash and every attempt. A failed quality
  result may still retain both OCR artifacts; record that as **failed**, not as
  a successful verification.
- Follow the **private artifact preview** links for that run's `ocr-pdf` and
  `ocr-text`; the authenticated endpoint reads the archive and verifies each
  stored checksum. Save both privately and run `sha256sum` locally. Require
  equality with each linked artifact's `output_sha256`, and inspect the OCR
  text against the selected source pages. Record artifact IDs, hashes, byte
  sizes and quality, not their private object keys or contents. Renew expired
  60-second preview links through the review page rather than bypassing access.
- Re-read the retained raw preview and compare its hash, version ID and byte
  size with the before-state. Confirm prior generations/artifact links remain.
  Content-addressed outputs may reuse identical artifact bytes or IDs: freshness
  comes from the new audited generation, execution timestamps/attempts and its
  artifact links, not from requiring a different output hash.
- Repeat image/health/actual-queue checks. Require the same OCR container/image,
  role `ocr`, an unpaused limit-1 consumer, unchanged resource caps, and retained
  downstream holds. Successful retry may resolve **its own case** through the
  normal pipeline; do not call `complete_retry`, close cases in bulk, or perform
  publication/correction actions. Releasing downstream work is a separate decision.

The sanitized receipt must contain: UTC observation times; operator/action/case
IDs; authoritative origin and source-version/raw hash; before-state run/artifact
IDs; new native and OCR run IDs/generation keys; attempt/provenance/limit/quality
results; verified `ocr-pdf` and `ocr-text` hashes; raw-before/raw-after equality;
and before/after image, consumer and hold checks. Mark it `passed`, `failed` or
`pending`, with any stop reason. Until that receipt is complete, report only
**readiness verified; fresh real-source OCR not yet verified**.
