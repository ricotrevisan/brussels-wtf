# ADR 0003: Reuse Coolify PostgreSQL and rustFS

- Status: accepted
- Date: 2026-08-11
- Decision issue: https://github.com/RicoTrevisan/brussels-wtf/issues/11

## Context

The Hetzner/Coolify estate already runs PostgreSQL and rustFS. brussels.wtf needs structured application state and a private immutable source archive, but does not need to deploy replacement storage services or own the estate-wide backup system.

## Decision

Reuse the existing PostgreSQL and rustFS services managed through Coolify.

### PostgreSQL

- Provision a dedicated logical database and least-privilege application role on the existing PostgreSQL service.
- Supply the connection through `DATABASE_URL` as a Coolify secret.
- Application releases run migrations against that database but do not create cluster-level roles or databases.

### rustFS

- Provision a dedicated private bucket and bucket-scoped credentials on the existing rustFS service.
- Configure the application with `SOURCE_ARCHIVE_S3_ENDPOINT`, `SOURCE_ARCHIVE_S3_BUCKET`, `SOURCE_ARCHIVE_S3_REGION`, `SOURCE_ARCHIVE_S3_ACCESS_KEY_ID`, and `SOURCE_ARCHIVE_S3_SECRET_ACCESS_KEY` as Coolify variables/secrets.
- Private source objects remain content-addressed and are never served as an unauthenticated public mirror.
- The application must fail fast at startup or release validation when the bucket is absent or inaccessible; it must not silently fall back to local disk.

### Provisioning and operations

- Database, role, bucket, and credentials are provisioned outside the application before its first production release.
- Coolify owns service connectivity and application secret injection.
- OCR remains isolated at concurrency `1`; transcription remains disabled until measured on representative files.
- Backups, off-host copies, retention, and restore testing are owned outside the brussels.wtf application/repository and are not a project launch gate. This ADR does not assert that any particular backup system exists.

## Consequences

- The application does not deploy PostgreSQL, rustFS, or a separate backup stack.
- Storage namespaces and credentials remain dedicated to brussels.wtf even though the underlying services are shared.
- Secrets and private endpoints stay out of Git, issue comments, logs, and public documentation.
- A later estate-wide backup decision can cover these namespaces without changing the application storage contract.
