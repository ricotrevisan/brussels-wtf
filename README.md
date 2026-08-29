# brussels.wtf

Evidence-backed reporting on municipal council meetings in Ixelles, Uccle,
Forest, and the City of Brussels.

The product will publish French, Dutch, and English coverage of upcoming
proposals and final decisions while preserving links to authoritative sources.

## Development

The app expects PostgreSQL. The local PostgreSQL service listens on port `5433`
with development credentials `brussels` / `brussels` and starts at boot.
Override it with `PGHOST`, `PGPORT`, `PGUSER`, and `PGPASSWORD` if needed.

```bash
mix setup
mix test
mix phx.server
```

Tidewave is enabled only in development. Company/person relationship facts may
publish only through the automated identity, authoritative-evidence, and privacy
rules in ADR 0004.

Planning is tracked through GitHub Issues. The implementation specification is
in `docs/specs/mvp-implementation.md`. Production rollout and rollback steps are
in `docs/operations/deployment.md`.
