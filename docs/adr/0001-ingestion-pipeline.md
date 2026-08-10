# ADR 0001: PostgreSQL-backed ingestion pipeline

- Status: accepted
- Date: 2026-08-10
- Decision issue: https://github.com/RicoTrevisan/brussels-wtf/issues/9

## Context

The four MVP communes expose different HTML/PDF structures and may replace bytes at stable URLs. The product must preserve exact evidence, normalize proposals separately from final decisions, and publish automatically only after language and evidence gates pass.

The production target is one Coolify/Hetzner host with shared PostgreSQL and rustFS. A live capacity check on 2026-08-10 found 4 CPUs, 7.6 GiB RAM, about 2.2 GiB available memory, and essentially full swap. CPU- and memory-heavy processing cannot be allowed to compete freely with the web service.

## Decision

Use one Phoenix/Ash codebase with PostgreSQL-backed Oban jobs, four explicit commune adapters, and a private content-addressed rustFS archive.

Ash resources and actions own lifecycle transitions, evidence relationships, validation, and publication gates. Plain Oban workers perform external I/O and invoke named Ash actions. Oban transport state is not the domain audit trail.

### Pipeline

1. `Oban.Plugins.Cron` enqueues a poll for each commune adapter.
2. The adapter snapshots its authoritative index and discovers exact source locators.
3. A fetch worker records every retrieval observation, hashes downloaded bytes, and writes new immutable source versions to `raw/sha256/{prefix}/{sha256}` in rustFS.
4. Born-digital PDFs use Poppler `pdfinfo` and `pdftotext` first. Page-level quality measurements decide whether the result is accepted.
5. Failed native extraction routes to OCRmyPDF/Tesseract with `fra+nld`, preserving the raw source and storing OCR output as a derived artifact.
6. Commune-specific normalization creates agenda items, proposals, decisions, evidence, and dossier-link inputs.
7. Content publishes when the independent FR/NL/EN and claim-evidence gates pass. Ambiguities create review cases.

### Queues

- `poll`: commune/index polling
- `fetch`: bounded HTTP and rustFS writes
- `extract`: Poppler/native extraction
- `ocr`: concurrency 1, hard memory/CPU/time limits
- `normalize`: commune-specific parsing and domain actions
- `publish`: language/evidence gate evaluation
- `transcription`: disabled by default for the MVP

The web release and lightweight workers may share one Coolify application initially. OCR must run as an isolated process role or service from the same release image with concurrency 1 and explicit resource limits. Transcription remains on-demand and disabled until a real bilingual recording benchmark proves the host can handle it; the current host pressure makes automatic transcription unsafe.

### Idempotency

PostgreSQL unique constraints are authoritative. Oban uniqueness only suppresses duplicate queue work.

- Stored bytes: `sha256(raw_bytes)`
- Source version: `(source_record_id, raw_sha256)`
- Retrieval observation: `(source_locator_id, poll_run_id)`
- Processing run: `(source_version_id, processor_name, processor_version, config_hash)`
- Derived artifact: `(input_sha256, processor_name, processor_version, config_hash, output_kind)`
- Transcription: `(audio_sha256, model_sha256, config_hash)`
- Review case: `(failure_kind, affected_record_id, processing_generation)`

A URL, filename, ETag, Last-Modified value, or agenda title is never sufficient deduplication evidence. Exact discovered URLs and redirect chains remain preserved even when normalized forms are stored.

### Polling

- Stagger commune polls every six hours.
- Re-fetch sources from 30 days before through 30 days after a meeting every six hours.
- Check daily until 180 days after a meeting, or until final records remain unchanged for 30 days.
- Poll the previous-year index daily for delayed records.
- Backfill older archives explicitly rather than continuously.
- Provide an authenticated `poll now` action.

Database `next_fetch_at` values determine due locators; do not create dynamic cron entries per URL.

### Retries and review

Use finite retries with jitter. Acquisition may retry up to six times across roughly 30 seconds, 2 minutes, 10 minutes, 1 hour, 6 hours, and 24 hours. Respect `Retry-After`; retry transient network failures, `408`, `425`, `429`, `5xx`, and newly discovered `404` responses. Deterministic corruption, authentication failures, invalid content, parser ambiguity, unsupported media, and repeated quality-gate failures create review cases instead of retry loops.

A review case shows the source URL, immutable snapshots, hashes, HTTP history, extracted/OCR text, processor logs, and affected records. Allowed actions create audited derived artifacts or domain revisions; they never mutate raw versions.

### Dependencies

Adopt, at implementation time, the then-current compatible releases of:

- Oban (`2.23.1` verified current on 2026-08-10)
- Req (`0.7.2` verified current)
- ReqS3 (`0.2.5` verified current), subject to an integration test against rustFS
- Poppler `pdfinfo` and `pdftotext`
- OCRmyPDF with Tesseract 5 and `fra`/`nld` language data
- FFmpeg and a pinned `whisper.cpp` binary/model only if transcription passes a separate benchmark

If ReqS3 fails path-style, endpoint, or large-upload tests against rustFS, use ExAws/ExAws.S3 rather than inventing an S3 client.

## Consequences

- Every source mutation and processing result is reproducible and auditable.
- Four adapters stay explicit instead of hiding incompatible municipal behavior behind a generic scraper.
- PostgreSQL remains the only queue and coordination dependency.
- OCR and transcription throughput is intentionally constrained.
- The MVP needs a small authenticated review queue.
- OCR thresholds, rustFS client behavior, and transcription capacity still require tracer-bullet tests against real documents and recordings.

## Rejected

- AshOban as the initial external-I/O pipeline abstraction
- Oban Pro workflows or dynamic cron
- Broadway, RabbitMQ, Kafka, Temporal, or microservices
- OCR on every PDF
- LLM/vision OCR as authoritative extraction
- automatic transcription of every recording
- URL/header-only deduplication
- using Oban job history as the editorial review system
