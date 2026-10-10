# Large supporting documents

Supporting-document acquisition uses a file-backed path with a 160 MiB cap.
Ordinary acquisition and in-memory PDF processing keep their 25 MiB defaults.
The `fetch` queue runs at concurrency one on the single app role, covering download,
archive upload, and verification. This also reduces ordinary fetch concurrency
from two to one. The queue limit is per app node; this is not a multi-node global limit.

Every accepted file is hashed in fixed-size chunks, uploaded to private content-addressed
storage, and verified by a streamed read-after-write. Failed and unchanged checks retain
retrieval observations. Failed-response validators cannot suppress the first archive.

Files larger than the configured processing limit are archived but not extracted or sent
to OCR. A version-linked extraction review case explains the deferral. Manual retries and
private raw previews reject oversized versions before loading bytes. The official source
link remains available. Acquisition does not imply permission for paid coverage generation.

Temporary workspaces have private permissions and are removed after success or failure.
A killed VM cannot execute cleanup; the deployment's ephemeral container filesystem removes
its temporary files when the container is replaced. This does not promise immediate cleanup
on VM death inside a retained container.

## Acceptance benchmark

Use only a disposable rustFS bucket and test credentials, never production credentials.
Configure the `RUSTFS_CONTRACT_*` variables documented by `test/contracts/rustfs_test.exs`.
Run:

```sh
MIX_ENV=test mix test --include external test/contracts/rustfs_test.exs:72
MIX_ENV=test mix run scripts/benchmark_large_sources.exs
```

The benchmark downloads 26, 64, and 160 MiB chunked responses to disk, verifies private
archive uploads and repeat immutable writes, and reports byte hashes, transfer times,
RSS/BEAM peaks, and temporary-file sizes. It never queues coverage or OCR.
An optional `LARGE_SOURCE_BENCHMARK_URL` measures an official source through the same path.
Run inside a constrained container and inspect cgroup memory as well as the reported RSS.
Keep the measurement receipt with the deployment evidence.

## Recovery

After the reviewed release is healthy, use authenticated locator `poll now` for the five
known September Brussels supporting PDFs. Do not use historical backfill or change the
standing schedule. Verify success observations, source-version hashes and byte counts,
private archive verification, and extraction-deferral review cases. Resolve prior acquisition
cases only after those receipts exist. Check the next scheduled cycle too.
A prior terminal scheduled failure may have cleared `next_fetch_at`. A locator
`poll now` success does not itself rearm scheduled fetches. Verify the locator's
schedule and the parent listing's rediscovery; do not claim automatic recovery
from a manual success alone.
