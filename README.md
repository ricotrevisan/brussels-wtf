# brussels.wtf

Evidence-backed reporting on municipal council meetings in Ixelles, Uccle,
Forest, and the City of Brussels.

The product will publish French, Dutch, and English coverage of upcoming
proposals and final decisions while preserving links to authoritative sources.

## Development

The app expects PostgreSQL. A dedicated local container is `brussels-pg` on
port `5433` (`brussels` / `brussels`). Override with `PGHOST`, `PGPORT`,
`PGUSER`, and `PGPASSWORD` if needed.

```bash
mix setup
mix test
mix phx.server
```

Tidewave is enabled only in development. Sensitive company/person relationship
routes stay disabled until the legal review in issue #12 is resolved.

Planning is tracked through GitHub Issues. The implementation specification is
in `docs/specs/mvp-implementation.md`.
