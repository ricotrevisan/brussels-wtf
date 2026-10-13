# File-backed one-page OCR contract

`BrusselsWtf.PDF.FileProcessor.ocr_page(meta, input_path, original_page,
workspace, opts \\ [])` returns file paths, sizes, safe diagnostics, tool versions,
duration and summary measurements. It never returns source/text binaries.
`ocr_metadata(opts \\ [])` returns a separate `ocrmypdf-file-page` identity and a
`pdf-file-ocr-page-v2` configuration hash covering fixed commands, limits,
Quality thresholds, original-page mapping, FileProcessor implementation bytes,
FileQuality implementation bytes, Python interpreter version and subprocess-wrapper
bytes. Native uses `pdf-file-native-v2` with the same implementation bindings.
Future schema/semantic changes must version this
contract. Native and ordinary binary-processor metadata remain separate.

## Required caller responsibilities

- Authorize only rejected native original pages; this low-level function is not
  a review action and does not decide or queue document recovery.
- Supply checksum/size-pinned, regular, unencrypted PDF input. Actual input count
  must be positive and at most 500; `original_page` must be a positive integer
  within that actual count. Input hashing streams under the shared deadline and
  160-MiB cap. Mount originals read-only.
- Supply a dedicated private 0700 tmpfs **mountpoint**, with `nodev,nosuid` and a
  kernel size limit at most 512 MiB. This bounds the total workspace, including
  all OCR descendant scratch and outputs, during execution. An ordinary folder,
  subdirectory of a shared tmpfs, or merely declaring a smaller cap fails closed
  with `{:invalid_workspace, :bounded_tmpfs_required}`. Lower `max_scratch_bytes`
  requires a correspondingly smaller actual mount, not just available space.
- Isolate the caller worker at one CPU, hard 1-GiB memory/no-swap, concurrency one,
  read-only root and no extra writable scratch escape paths. The subprocess
  wrapper enforces one cumulative 90-second owned-process-tree CPU budget across
  every command and version probe in **one invocation**, independently of the
  harness's whole-cgroup monitor. An invocation-private locked ledger debits
  ceil-rounded waited CPU deltas (including the fresh Python supervisor). Kernel
  per-process limits round remaining seconds down; less than one second remaining
  fails before spawning another command. This is intentionally conservative for
  reduced limits. A 10-ms watchdog sums live `/proc` CPU and waited-descendant
  `cutime/cstime`, including subreaper-adopted escaped sessions; it reserves 50 ms
  for accounting granularity and cleanup. Final waited usage is authoritative.
  Polling is not a zero-overshoot kernel tree limit: focused one-CPU contracts
  assert at most 100-ms tolerance, and scheduler stalls/concurrent CPUs can widen
  that tolerance. Exhaustion returns `{:processor_limit, :cpu}` and cleans outputs.
  The caller still separately enforces cumulative **multi-page** work budgets.
- Archive both returned files before deciding acceptance and then clean the
  caller-owned workspace. Rejected Quality still returns both files. Mechanical
  Quality acceptance is not semantic correctness or publication authorization.

## Processing and output

1. Validate source metadata/checksum, actual PDF count and original page index.
2. Run fixed `qpdf input --pages input original_page -- subset.pdf` under the
   bounded wrapper. Require a one-page subset and at most 25 MiB, without
   compression/downsampling escape behavior.
3. OCR **only that subset**, using ordinary `--redo-ocr --rotate-pages --jobs 1
   --language fra+nld --output-type pdf --verbose 1` flags. No whole-source
   repeated `--pages` OCR and no force-OCR profile options are accepted.
4. Require a positive, exactly one-page OCR PDF; extract with `pdftotext -layout`
   to a private file. PDF and whole text caps are 64 MiB; per-page text is 256 KiB.
   All stages share the same 120-second deadline, including hashing and probes.
5. Apply unchanged FileQuality/Quality with exact terminal form-feed completeness.
   `quality_measurements.pages` and `rejected_pages` stay **local page 1**;
   `original_pages: [original_page]` explicitly maps to the original source.
6. Return `text_path`, `searchable_pdf_path`, `text_byte_size`, `pdf_byte_size`,
   `page_count: 1`, `original_pages`, `quality_measurements`, `output` (summary
   only), safe `diagnostics`, `tool_versions`, and `duration_ms`. Files are 0600.
   Remove subset/diagnostics/internal scratch on success; remove only the
   processor-owned directory on operational failure.

## Offline exact-image verification

The imported image is pinned in `run_file_ocr_contract.py`; it is not rebuilt.
Its actual qpdf is **11.3.0**, not a Poppler 22.x version. Poppler is 22.12.0,
OCRmyPDF 14.0.1, Tesseract 5.3.0 and Ghostscript 10.00.0. ExUnit is supplied from
the host's matching Elixir installation because release images omit test libs;
Quality comes from the image's deployed BEAM and build-time thresholds. No app,
DB, network, serving container or queue is started.

```sh
python3 /home/rico/brussels-wtf-large-pdf-processing/test/support/pdf_contract/run_file_ocr_contract.py

python3 /home/rico/brussels-wtf-large-pdf-processing/test/support/pdf_contract/run_file_ocr_contract.py \
  --cover-source /path/to/approved/01a126d0-ef31-7b01-ac95-92bf2bc158f8.pdf
```

The cover command accepts only the recorded FR diagnostic SHA/size and selects
original page 1. The default runs focused native/FileQuality/one-page OCR tests
and trusted hostile-wrapper hazards (CPU, memory, wall time, diagnostics, file
limits, escaped descendants, scratch byte quota and inode quota). Each run
prints its outside-repository private receipt directory. Receipts include
before/after Docker inspect, whole-cgroup usage, code hashes and no-app evidence;
cover receipts additionally retain verified OCR artifact hashes/page map and
private 0600 output files. The caller's production quota-backed worker and
cumulative multi-page budget remain future integration work, not implemented or
authorized by this contract.
