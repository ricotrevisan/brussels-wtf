# Production deployment

Production runs in Coolify from one Docker image with separate `app` and `ocr`
roles. PostgreSQL 17 and the private rustFS bucket are external services. Never
deploy a local working tree or run migrations from a developer machine.

## Pre-deploy gate

From a clean checkout:

```bash
git fetch origin
sha=$(git rev-parse origin/main)
test "$(git rev-parse HEAD)" = "$sha"
test -z "$(git status --porcelain)"
gh run list --commit "$sha" --workflow CI --limit 1
docker build --build-arg SOURCE_COMMIT="$sha" --target runner -t "brussels-wtf:$sha" .
PRODUCTION_IMAGE="brussels-wtf:$sha" MIX_ENV=test \
  mix test --include external test/contracts/production_image_pdf_test.exs test/contracts/production_image_ocr_readiness_test.exs
```

Deploy only after CI, the full local pre-commit suite, both review axes, and the
production-image contract pass. The OCR contract creates disposable containers
and a private test network. It keeps the one-CPU/1-GiB envelope and sets a 65,536
file-descriptor limit for reproducible Erlang port-table sizing on Docker hosts
with unusually high default `nofile` limits. On 2026-09-11, the local daemon's
1,073,741,816-descriptor default caused a 1.5-GiB Erlang port table before app
startup. The fixture limit reduced bare-release memory from about 2.18 GB to
38 MB. The deployed OCR limit observed that day was 1,024, below the fixture's
65,536; no production memory limit was raised. See
[incident #74](https://github.com/RicoTrevisan/brussels-wtf/issues/74). The RPC client independently caps
its port table at 1,024. Recheck actual limits when comparing other hosts.
Fault-injection cases use controlled
dependency results with the real monitor and Oban consumer. A separate case runs
the unmodified OCR entrypoint against disposable PostgreSQL and rustFS and
requires validation, a healthy consumer, and no HTTP listener. Test images are
`postgres:17-alpine`, `rustfs/rustfs:latest`, and `minio/mc:latest`; the contract
allows image overrides for repeatable local runs. It does not validate the
estate's live storage network, credentials, or Coolify network attachments.

One case starts the committed `docker-compose.ocr.yml` itself with
`docker compose`. Its override only joins the disposable network and sets the
same 65,536 `nofile` limit. It requires a healthy worker, Docker limits of one
CPU, 1 GiB memory, 1 GiB memory+swap and 512 PIDs, and kernel cgroup values
`memory.max=1073741824` and `memory.swap.max=0`. A 1.25-GiB allocation must be
OOM-killed with zero swap used while the worker stays healthy. Every path the
runtime user can write must be inside `/tmp` or the OCR scratch mount; root and
the runtime user both get `Read-only file system` elsewhere. `/tmp` must refuse
writes past 256 MiB. Ordinary OCR and file-backed page OCR must still succeed
inside the running container. The check reads cgroup v2 files; run it on a
cgroup v2 Docker host with swap enabled, or it proves less.

## Coolify rollout

1. Pin the reviewed commit. Build one image with `SOURCE_COMMIT` set to its full
   Git SHA.
2. Deploy the `app` role first with `PROCESS_ROLE=app`. Keep the previous
   healthy container in service until `/health/ready` returns 204.
3. Confirm `/health/version` returns the pinned SHA. Confirm migrations and the
   private archive validation succeeded in redacted logs.
4. Deploy the exact same image to the private `ocr` role with
   `PROCESS_ROLE=ocr`, queue concurrency 1, one CPU, 1 GiB hard memory with
   no swap, and a read-only root filesystem.
5. Prove both roles use the same image digest. Check the OCR health probe and its
   live queue state after startup. A running container alone is not readiness.

Both roles require `DATABASE_URL`, `SECRET_KEY_BASE`, `REVIEW_USERNAME`,
`REVIEW_PASSWORD`, and all five `SOURCE_ARCHIVE_S3_*` variables. Set
`PHX_HOST=brussels.wtf` and `PORT=3000`. Traefik must set
`x-forwarded-proto`; TLS terminates at the ingress.

## Smoke checks

```bash
base=https://brussels.wtf
curl -fsS "$base/health/version"
test "$(curl -sS -o /dev/null -w '%{http_code}' "$base/health/live")" = 204
test "$(curl -sS -o /dev/null -w '%{http_code}' "$base/health/ready")" = 204
for lang in fr nl en; do curl -fsS -o /dev/null "$base/?lang=$lang"; done
curl -fsS -o /dev/null "$base/review/login"
```

Also check identity routes with known public, private-only, retired, malformed,
and unknown identifiers. Private fields and suggestion content must never occur
in public HTML, logs, flashes, or health responses.

Readiness is not proof of a fresh OCR artifact. For the separate one-source
acceptance step, follow [bounded real-source OCR verification](pdf-processing.md#bounded-real-source-ocr-verification).
Do not claim fresh production OCR until its audited, checksum-verified receipt exists.

## Rollback

Do not run migration `down` functions as an incident response. App startup runs
migrations before validation, so a failed release can leave the schema ahead of
the serving code.

1. Remove the failed container from traffic and keep the previous healthy app
   serving.
2. Inspect the applied migrations and prove the previous image is compatible
   with the upgraded schema before redeploying it.
3. Roll both roles back to the same previously known-good image digest.
4. If the prior image is incompatible, stop the rollout and use the operator's
   verified PostgreSQL backup/restore procedure. The repository does not own or
   assert that external backup system.

## Private suggestion intake

Production enables suggestion intake by default with `SUGGESTIONS_ENABLED=true`; set it to `false` for a legal or operational hold. The application derives a domain-separated 32-byte HMAC key from `SECRET_KEY_BASE`. `SUGGESTION_RATE_LIMIT_SECRET` is an optional rotation override, not a required Coolify secret.

Forwarded client addresses are ignored unless the immediate peer is listed in the comma-separated `SUGGESTION_TRUSTED_PROXIES` setting. List only the exact canonical IP addresses of trusted Traefik hops. An empty list uses the socket peer and cannot be spoofed with `X-Forwarded-For`.

### Reusing the app image for OCR

The OCR application uses the repository's `docker-compose.ocr.yml` with Coolify's
Docker Compose build pack. Set `APP_IMAGE` to the local image tag shown by the
successful app build (`sn1f08alzbb5reus2ynxrswz:<full-commit>` on this estate).
`pull_policy: never` makes a missing local image fail instead of obtaining a
different artifact. Do not independently rebuild the OCR role. The compose
service sets one CPU, 1 GiB memory with no swap (`memswap_limit` equals
`mem_limit`), 512 PIDs, and no public ports.

The root filesystem is read-only, with `ipc: none` (no `/dev/shm`). The only
writable paths are two private 0700 `nosuid,nodev,noexec` tmpfs mounts owned by
65534:65534: the 512-MiB `/app/large-pdf-ocr-scratch` and a 256-MiB `/tmp` for
`System.tmp_dir!/0` and ordinary OCR temporary files. Docker's POSIX
message-queue mount is covered read-only. Tmpfs pages count toward the 1 GiB and
cannot swap, so ordinary OCR that needs more than 256 MiB of scratch fails with
`No space left on device` instead of spilling to disk. The release itself writes
nothing at startup: its `sys.config` needs no runtime rewrite. Tmpfs contents
are lost on restart, so `ERL_CRASH_DUMP_SECONDS=0` skips Erlang crash dumps;
use the container logs. Preserve the existing
OCR application's database and private-archive credentials. Both deployments
must use the same Coolify server.

Set `connect_to_docker_network=true` on the Coolify OCR Compose application.
This joins the pre-existing destination network so the private PostgreSQL and
rustFS service names resolve. A Compose-only network cannot reach those names.
Check the deployed OCR network attachments against the healthy app; do not
publish storage ports or substitute public storage endpoints to bypass a missing
network attachment.

Since Coolify 4.5.0, Compose interpolates `${VAR:?}` only from variables marked
**Available at buildtime**. Every variable the Compose file requires must be
both build-time and runtime in the OCR application, or the deployment fails
with `required variable … is missing a value` while the previous container keeps
running. When `docker-compose.ocr.yml` gains a required variable, mark it
build-time before deploying. Coolify's API returns no log for these failures;
the log is in its `application_deployment_queues` table.

### OCR readiness and read-only diagnostics

Both the image and Compose use `/app/bin/ocr_ready`. It performs a bounded RPC
against the **running release**, not `eval` in a separate application VM. It
succeeds only for runtime role `ocr`, a fresh successful dependency-readiness
cache, and a live, unpaused local `ocr` consumer with limit 1. Startup validation,
a missing/crashed release or consumer, a paused/mis-sized queue, stale/failed
readiness, and a timed-out RPC all fail closed. No public HTTP listener is needed.
The probe does not run validation, write archive objects, migrate, enqueue jobs,
or resume queues. The existing monitor refreshes dependency readiness separately.

On the Coolify server, use the exact deployed container names:

```bash
docker inspect --format '{{.Image}}' "$APP_CONTAINER" "$OCR_CONTAINER"
docker inspect --format '{{json .NetworkSettings.Networks}}' "$OCR_CONTAINER"
docker inspect --format '{{json .State.Health}}' "$OCR_CONTAINER"
docker inspect --format '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}} {{.HostConfig.ReadonlyRootfs}} {{json .HostConfig.Tmpfs}}' "$OCR_CONTAINER"
docker exec "$OCR_CONTAINER" cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max
docker exec "$OCR_CONTAINER" /app/bin/ocr_ready
docker exec "$OCR_CONTAINER" timeout --kill-after=1s 3s /app/bin/brussels_wtf rpc \
  'IO.inspect(%{role: Application.get_env(:brussels_wtf, :process_role), ready: BrusselsWtf.ProcessRole.ocr_ready?(), queue: case Oban.check_queue(queue: :ocr) do nil -> nil; queue -> Map.take(queue, [:queue, :paused, :limit]) end})'
```

The two image IDs must match. Repeat readiness checks after the startup grace
period; one transient healthy sample is not rollout evidence. Docker health
status alone does not restart an unhealthy container under `unless-stopped`.
Investigate the failed dependency or consumer before any operator-authorized
restart. Never use `Oban.start_queue`, `resume_queue`, or job insertion as a
read-only health check.

The build embeds `priv/source_commit` in the release. `/health/version` reads
that file before considering a fallback `RELEASE_SHA` environment variable, so
runtime environment configuration cannot relabel a built image.
