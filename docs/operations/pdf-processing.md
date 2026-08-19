# PDF extraction and OCR operations

Issue #21 introduces a Poppler-first extraction contract. Every PDF is checked by `pdfinfo` and extracted with `pdftotext` before OCR is considered. Page decisions, executable versions, safe command outcomes, language signals, timings, and configuration hashes are retained on the processing generation. Native text is always archived as a private derived artifact.

## Calibrated quality contract

The versioned corpus is in `test/support/pdf_contract/manifest.json`. It contains agent-authored CC0 structural fixtures for Ixelles, Uccle, Forest, and the City of Brussels, plus image-only and malformed hazards. It does not reproduce municipal text. The pinned production-image contract is authoritative because developer machines need not contain Poppler or OCR.

The `pdf-extraction-v1` thresholds are explicit in `config/config.exs`:

- at least 40 trimmed characters per page;
- at least 6 words per page;
- alphanumeric/non-space ratio of at least 0.5;
- control-character ratio no greater than 0.01;
- replacement-character ratio no greater than 0.005.

A single rejected page rejects native extraction for the document. Only rejected page numbers are sent to OCRmyPDF with Tesseract `fra+nld`; accepted pages are retained and are not re-OCRed. Normalization reads the checksum-verified accepted text artifact, never an unarchived processor response.

## Isolation and limits

The same release image has two mutually exclusive roles:

- `PROCESS_ROLE=app`: web, polling, fetching, native extraction, normalization, and publication; it cannot consume OCR jobs.
- `PROCESS_ROLE=ocr`: no Phoenix server or cron plugins, and only the `ocr` queue at concurrency 1.

Run `/app/bin/ocr_worker` in the OCR service. Migrations remain owned by the app role. The production image pins Debian Bookworm and contains Poppler 22.12, OCRmyPDF 14.0, Tesseract 5.3, and the `fra`, `nld`, and `osd` data packages. Release validation fails closed when the toolchain or bilingual language data is missing. Automatic transcription is explicitly disabled.

The calibrated defaults are 25 MiB input, 500 pages, 120 seconds wall time, 90 CPU seconds, 1 GiB address space, and one OCRmyPDF job. A 2026-08-19 run of the partial-scan contract in the release image, capped at one CPU and 1 GiB, completed in 8.4 seconds and peaked at about 180 MiB. The defaults provide headroom for representative documents while the separate role, queue concurrency, cgroup limits, `timeout`, and `prlimit` protect the app/database/archive processes. Configure the Coolify OCR container with one CPU and 1 GiB hard memory. Runtime overrides are `PDF_MAX_INPUT_BYTES`, `PDF_MAX_PAGES`, `PDF_OCR_WALL_TIME_MS`, `PDF_OCR_CPU_SECONDS`, and `PDF_OCR_MEMORY_BYTES`.

## Failure and observability

Poor native quality is routing, not a terminal failure. Invalid/malformed input, oversized input, and exhausted CPU/memory/wall limits are classified and converge on one private extraction review case per processing generation. Other executable failures retry at most three times. Reviewer retry appends a new generation and never mutates raw bytes or prior artifacts.

Safe telemetry covers page rejection counts, native/OCR duration, OCR routing, bounded retries, review-case creation, backlog, and oldest OCR queue age. Correlation identifiers include source version, processing run, and review case. Logs exclude object keys, source bytes/text, command output, endpoints, credentials, and private diagnostics.

Run the image contract with:

```sh
docker build --target runner -t brussels-wtf:pdf-contract .
PRODUCTION_IMAGE=brussels-wtf:pdf-contract mix test --include external test/contracts/production_image_pdf_test.exs
```
