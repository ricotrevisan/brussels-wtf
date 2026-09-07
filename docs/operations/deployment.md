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
  mix test --include external test/contracts/production_image_pdf_test.exs
```

Deploy only after CI, the full local pre-commit suite, both review axes, and the
production-image contract pass.

## Coolify rollout

1. Pin the reviewed commit. Build one image with `SOURCE_COMMIT` set to its full
   Git SHA.
2. Deploy the `app` role first with `PROCESS_ROLE=app`. Keep the previous
   healthy container in service until `/health/ready` returns 204.
3. Confirm `/health/version` returns the pinned SHA. Confirm migrations and the
   private archive validation succeeded in redacted logs.
4. Deploy the exact same image to the private `ocr` role with
   `PROCESS_ROLE=ocr`, queue concurrency 1, one CPU, and 1 GiB hard memory.
5. Prove both roles use the same image digest.

Both roles require `DATABASE_URL`, `SECRET_KEY_BASE`, `REVIEW_USERNAME`,
`REVIEW_PASSWORD`, and all five `SOURCE_ARCHIVE_S3_*` variables. Set
`PHX_HOST=brussels-wtf.nocode-to-knowcode.com` and `PORT=3000`. Traefik must set
`x-forwarded-proto`; TLS terminates at the ingress.

## Smoke checks

```bash
base=https://brussels-wtf.nocode-to-knowcode.com
curl -fsS "$base/health/version"
test "$(curl -sS -o /dev/null -w '%{http_code}' "$base/health/live")" = 204
test "$(curl -sS -o /dev/null -w '%{http_code}' "$base/health/ready")" = 204
for lang in fr nl en; do curl -fsS -o /dev/null "$base/?lang=$lang"; done
curl -fsS -o /dev/null "$base/review/login"
```

Also check identity routes with known public, private-only, retired, malformed,
and unknown identifiers. Private fields and suggestion content must never occur
in public HTML, logs, flashes, or health responses.

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
service sets one CPU, 1 GiB memory, no public ports, and a process health check;
the HTTP readiness check belongs to the app role. Preserve the existing OCR
application's database and private-archive credentials. Both deployments must
use the same Coolify server.

The build embeds `priv/source_commit` in the release. `/health/version` reads
that file before considering a fallback `RELEASE_SHA` environment variable, so
runtime environment configuration cannot relabel a built image.
