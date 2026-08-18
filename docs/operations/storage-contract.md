# Storage contract validation

Issue [Validate Coolify PostgreSQL and rustFS production contracts](https://github.com/RicoTrevisan/brussels-wtf/issues/27) is the evidence log for this operational contract. Never put endpoints, database names, bucket names, roles, object keys, or credential fragments in that log.

## Release and health contract

The release image runs these steps in order:

1. `BrusselsWtf.Release.migrate/0`
2. `BrusselsWtf.Release.validate/0`
3. the Phoenix server

Validation fails closed unless every application migration is up and the private source archive passes a write, metadata, read, delete, and absence check below `_validation/brussels-wtf`. The application never creates a database, role, bucket, policy, credential, or backup.

`/health/live` is a dependency-free liveness check. `/health/ready` reads a cached check that starts unavailable, verifies database migration state plus the same disposable archive contract away from the HTTP request, and expires after 90 seconds. Archive validation uses six bounded, non-retrying five-second request windows (five contract operations plus best-effort cleanup), and the monitor's five-minute hard timeout exceeds that cumulative window with ample margin. The release image health check uses `/health/ready`; configure Coolify rollout readiness to use the same path. Do not use `/health/live` to decide whether a release may receive traffic.

## ReqS3 adoption gate

Run the live tests from inside the same private network as the preview application. Use a dedicated non-production database and rustFS bucket. The rustFS credential must be scoped to that bucket. `RUSTFS_CONTRACT_DENIED_BUCKET` must name an existing operator-provisioned canary bucket to which that credential has no access; a random absent name does not prove scope.

```bash
RUSTFS_CONTRACT_ENDPOINT='(private value)' \
RUSTFS_CONTRACT_BUCKET='(private value)' \
RUSTFS_CONTRACT_DENIED_BUCKET='(private value)' \
RUSTFS_CONTRACT_REGION='(private value)' \
RUSTFS_CONTRACT_ACCESS_KEY_ID='(secret)' \
RUSTFS_CONTRACT_SECRET_ACCESS_KEY='(secret)' \
MIX_ENV=test mix test --include external test/contracts/rustfs_test.exs
```

The suite proves real SigV4 endpoint/region/path-style compatibility, content-addressed write and read-after-write hashing, metadata, a deterministic 64 MiB upload, disposable-prefix delete access, anonymous-read denial, unavailable bucket enumeration, and explicit canary-bucket GET/PUT denial. Its two deterministic raw fixtures remain for the non-production bucket lifecycle to clean up; application credentials deliberately have no raw-object delete interface.

Retain ReqS3 only after this exact suite passes. If it fails because ReqS3 is incompatible with rustFS, implement the existing `BrusselsWtf.Archive` behaviour with ExAws/ExAws.S3 and run the same behavioral contract. Do not build a custom S3 client.

## PostgreSQL contract

The contract role must have the application-database migration rights supplied by the operator and must not be superuser, `CREATEDB`, `CREATEROLE`, replication, or `BYPASSRLS` capable.

```bash
POSTGRES_CONTRACT_URL='(secret)' \
POSTGRES_CONTRACT_DATABASE='(private value)' \
POSTGRES_CONTRACT_ROLE='(private value)' \
MIX_ENV=test mix test --include external test/contracts/postgres_test.exs
```

The suite checks the exact logical database and role, negative cluster privileges, applied migration state, and an application-schema create/write operation inside a rolled-back transaction. It does not provision or retain anything.

## Redacted evidence

Record only:

- UTC run time and commit SHA
- ReqS3 version and `path-style` addressing
- representative upload byte count
- pass/fail for PostgreSQL identity/privileges/migrations/write
- pass/fail for rustFS signed CRUD/metadata/hash/privacy/scope

If any check fails, record only its operation and coarse category. Raw Req/Postgrex errors can contain private endpoints, identifiers, object keys, or credential fragments and must not be copied into logs, issues, or client responses.
