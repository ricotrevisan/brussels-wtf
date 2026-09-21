# CBE Open Data private enrichment

The application reads a privately provisioned full CBE Open Data release. It does not scrape or systematically reuse CBE Public Search. Provisioning and importing are explicit operator actions; there is no automatic downloader, updater, import at startup, or CSV fallback from the index.

## Provision a full release

1. Register for [CBE Open Data](https://economie.fgov.be/en/themes/enterprises/crossroads-bank-enterprises/services-everyone/public-data-available-reuse/cbe-open-data), accept its current terms, and download a full release. The FPS also documents optional registered SFTP access.
2. Retain the downloaded archive privately and record its SHA-256 digest.
3. Extract the release into a private, read-only directory containing `meta.csv`, `code.csv`, `enterprise.csv`, `establishment.csv`, and `denomination.csv`. The expected format is defined by the official [CBE Open Data cookbook](https://economie.fgov.be/sites/default/files/Files/Entreprises/BCE/Cookbook-BCE-Open-Data.pdf).
4. Retain a trusted provisioning receipt with the archive digest, metadata, and each of those five extracted files' byte length and SHA-256. Keep source files and receipts out of Git and public storage. Do not regenerate the receipt from suspect files merely to make verification pass.

## Runtime selection

| `CBE_LOOKUP_MODE` | Other configuration | Result |
| --- | --- | --- |
| Unset or `csv` | Neither directory nor digest | `BrusselsWtf.CBE.Unconfigured`; enrichment fails closed |
| Unset or `csv` | Both `CBE_OPEN_DATA_DIRECTORY` and `CBE_OPEN_DATA_SHA256` | Existing streaming CSV adapter |
| `indexed` | `CBE_OPEN_DATA_SHA256` required; directory optional | PostgreSQL adapter pinned to that exact release |

Digests must contain exactly 64 hexadecimal characters; runtime selection normalizes uppercase to lowercase. Empty directory/digest values count as absent. Unknown or empty modes, partial CSV configuration, and absent/invalid indexed digests prevent startup without echoing their values.

CSV mode mounts the directory into `PROCESS_ROLE=app` and scans the CSV files for explicit enterprise-number lookups. Release validation intentionally does **not** verify CSV availability or contents, preserving the initial-deployment provisioning sequence.

Indexed configuration selects an adapter without querying PostgreSQL. After migrations, before application startup, `BrusselsWtf.Release.validate/0` separately requires `BrusselsWtf.CBE.Indexed.ready?/0` to succeed for the selected digest. Missing, staging, incompatible, or unavailable indexes fail closed; they never trigger an import or fallback. `PROCESS_ROLE=ocr` skips this app-index readiness requirement. Once ready, indexed lookups require PostgreSQL but **no source-directory mount**.

## Explicit index import

Use the release image with its ordinary database configuration. Run migrations first. Leave the running app on its current CSV/unconfigured mode or previous ready digest until the new import finishes. Invoke `eval`, not `rpc`: this starts only index dependencies and Repo, never the application supervisor, web server, or Oban queues.

The trusted manifest is a JSON object of at most **1 MiB (1,048,576 bytes)**, matching the provisioned full-release receipt:

```json
{
  "sha256": "<lowercase 64-hex digest of the downloaded archive>",
  "metadata": {"ExtractNumber": "<recorded extract number>", "SnapshotDate": "<recorded snapshot date>"},
  "files": {
    "meta.csv": {"bytes": 123, "sha256": "<lowercase 64-hex file digest>"},
    "code.csv": {"bytes": 123, "sha256": "<lowercase 64-hex file digest>"},
    "enterprise.csv": {"bytes": 123, "sha256": "<lowercase 64-hex file digest>"},
    "establishment.csv": {"bytes": 123, "sha256": "<lowercase 64-hex file digest>"},
    "denomination.csv": {"bytes": 123, "sha256": "<lowercase 64-hex file digest>"}
  }
}
```

Replace illustrative lengths and placeholders with the trusted receipt values. `metadata` is a retained object, not a way to override CSV metadata; the importer validates full-release metadata from `meta.csv`. The `files` object must contain exactly these five names, each with a positive byte length and lowercase digest. A download inventory such as `download-manifest.json` is **not** this extracted-file receipt. Hashes bind files to the trusted receipt; they do not independently authenticate its origin or re-verify the original archive.

For example, with private paths supplied via operator-controlled environment variables:

```sh
bin/brussels_wtf eval 'BrusselsWtf.Release.migrate()'
bin/brussels_wtf eval '
  case BrusselsWtf.Release.import_cbe_index(
    System.fetch_env!("CBE_IMPORT_DIRECTORY"),
    System.fetch_env!("CBE_IMPORT_MANIFEST"),
    batch_size: 1000, max_batches: 10
  ) do
    {:ok, summary} -> IO.inspect(summary)
    {:error, _} -> IO.puts(:stderr, "CBE index import failed"); System.halt(1)
  end'
```

`CBE_IMPORT_DIRECTORY` and `CBE_IMPORT_MANIFEST` above are inputs to this command only, not runtime adapter settings. The command returns `{:ok, summary}` for both `:staging` and `:ready`; check `summary.state`. Summaries contain only digest, state, projection version, row counts, progress, and completed file names, not company data, metadata, credentials, or private paths. Avoid printing manifests, source rows, or raw configuration to logs.

Import limits (passed as keyword options):

- `batch_size`: integer **1..1000**, default **1000**.
- `max_batches`: positive integer or `:infinity`, default `:infinity`. Use a finite value for bounded operator invocations.
- `max_record_bytes`: integer **1..1,048,576**, default **1,048,576**.
- `max_batch_bytes`: integer from `max_record_bytes` through **16,777,216**, default **4,194,304**.
- `meta.csv` and `code.csv` are each limited to **16 MiB** by the backend.

Repeat the same command with the **same receipt and directory bytes** to resume committed logical-row checkpoints until `state: :ready`. Each invocation rehashes the source files and reparses the current file's committed prefix once; batches within that invocation do not rescan it. Use a small batch budget for the first capacity sample, then a substantial invocation budget. Repeating single-batch invocations across a whole release incurs quadratic prefix replay and is not the intended bulk-import procedure. An invocation may stop at a batch boundary before marking a file complete; a subsequent invocation finishes that bookkeeping. A ready import is idempotent. Competing importers may return `:concurrent_import`; run one operator import at a time and retry deliberately. Altered files, receipts, or incompatible projection versions do not silently replace an existing release.

## Activate, roll back, or reimport

1. Finish the import and confirm `state: :ready`. With Repo running, `BrusselsWtf.CBE.Index.status(sha256)` returns the same safe summary for an exact digest; it does not select or activate anything.
2. Explicitly set `CBE_LOOKUP_MODE=indexed` and `CBE_OPEN_DATA_SHA256` to that imported archive digest on the **app** service. Redeploy through the usual migrate → release validation → app-start sequence. There is no implicit latest-release selection.
3. Validate the selected release and exercise a known enterprise-number lookup. The source mount can be removed from the app service; retain the private original archive, extracted files, and receipt for reproducibility and reimport.
4. To roll back, restore the previous **ready** digest and redeploy. Old index releases are retained, not automatically pruned or overwritten. To return to CSV intentionally, set `CBE_LOOKUP_MODE=csv` and restore both its directory mount and digest; this is an operator action, never automatic fallback.
5. After index data loss, reimport from the trusted retained receipt and identical source bytes before selecting that release. An already-ready import does not rebuild or repair rows. A manifest conflict or incompatible projection requires investigation and an explicit maintenance/migration plan, not a new receipt fabricated under the same archive identity.

## Read-only acceptance benchmark

The release includes `priv/ops/cbe_index_benchmark.exs`. With Repo running, load it using `Code.eval_file(Application.app_dir(:brussels_wtf, "priv/ops/cbe_index_benchmark.exs"))`, then call:

```elixir
BrusselsWtf.Ops.CBEIndexBenchmark.run(archive_sha256, enterprise_numbers,
  repeats: 10,
  compare_directory: mounted_csv_directory
)
```

Supply at most ten explicit enterprise numbers and 1–100 repetitions. Omit `compare_directory` for a no-files lookup check. Output contains latency, found/not-found status, deterministic bundle hashes, and parity—not registered names or source rows. A comparison mismatch aborts rather than printing the differing private records. First-use measurements do not imply cold PostgreSQL or OS caches; never flush shared production caches. Compare representative companies, a high-establishment-count registration, and an absent identifier. Capture import elapsed time, peak container memory, database/index size and disk headroom separately.

## Resources and evidence boundaries

Import streams bounded records/batches but hashes source files for verification, rechecks files before sealing, and may reread committed prefixes on resume. `max_batches` bounds newly committed batches, **not total file I/O or wall time**. Plan private source-disk capacity plus PostgreSQL table/index/WAL capacity for the new and retained old releases, and monitor database load, memory, disk, and elapsed time on the shared host. Limit parallel work and choose batch limits conservatively. No measured latency, memory, disk, or throughput improvement is claimed here; benchmark representative data before making numerical claims.

Both adapters retain extract number, snapshot date, format version, and supplied archive digest. They ignore contact and address files. Natural-person registrations remain marked as such and cannot create a legal entity. The application queue handles enrichment asynchronously at concurrency one, independently of neutral meeting publication. The index changes lookup storage, not privacy policy or evidence gates: private candidate facts do not become public ownership, management, or council-member relationship claims. Name similarity and inference remain insufficient evidence.
