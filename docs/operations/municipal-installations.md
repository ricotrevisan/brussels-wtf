# Municipal installations: bounded publication v1

This is the reviewed operating procedure for the MunicipalInstallation lane, not
an assertion that it has been deployed or run in production. Issue #104's full
acceptance may remain open: correction and cessation are unsupported in this v1
and fail closed. They need a follow-up source-specific verifier and preserved
history, not a manual change to verification status.

## What is published

A completed installation documented on **2024-12-01**, supported by an official
municipal PDF and independently corroborated identity in a different official
PDF. It is a **historical installation**, not proof of present office or
continuous tenure. `effective_to: nil` means the end date is unknown; it does not
mean “Current”, “Ongoing”, or “until 2030”. Later attendance/role evidence is used
for identity corroboration, not to extend the installation period.

The public projection has `state: :documented`. Profiles place it in dated
history; the homepage discovers all published installation roles through the
same verified projection and respects commune filters. FR/NL/EN explain:
“Installation documented on 2024-12-01; end date not established.” Citations link
to the official installation PDF at `#page=N`, not to private archive objects.
Public pages do not expose source excerpts, corroboration maps, private identity
fields, or verification internals. Existing declaration reporting periods and
Gazette role states remain separate semantics.

Role translations come from the source policy's locale labels, not from guessing
gender from a name. Changes to that terminology belong centrally in the policy,
not in person-specific UI overrides.

## Approved evidence scope

`BrusselsWtf.Identity.MunicipalInstallation.Source.contracts/0` is the authority
for exact URLs, discovered parent indexes, dates, source roles, immutable hashes,
and parser layouts. There are **eight pinned PDF source versions**, two per
commune (index HTML observations are additional acquisition evidence):

| Commune | Installation PDF | Independent corroboration PDF |
|---|---|---|
| Ixelles | Minutes 245, 2024-12-01 | Minutes 267, 2026-06-11 |
| Uccle | Register 2024-12-01 | Register 2025-06-26 |
| Forest | Minutes 2024-12-01 | Minutes 2026-03-24 |
| City of Brussels | Complete report 2024-12-01 | Complete report 2026-04-20 |

The gate is automated **within these inspected source layouts and versions**;
it is not permission to publish arbitrary future records. No person-name
allowlist or per-person approval bottleneck is part of this lane. Exact full-name
corroboration, completed-event semantics, bounded source sections and privacy
rules still apply to every fact. Surname-only lists, uncertain ranks, unsupported
replacement blocks and ambiguous identities remain excluded. Other inspected
but unimplemented offices are not silently in scope.

The private audit at `/tmp/issue104-sources/role-safe/README.md` records the earlier
runtime inventory and source-layout investigation. It is not live runtime state
or a production publication receipt. Do not commit its PDF bytes or private
excerpts, and do not substitute its prototype parser outputs for the gate.
Installation PDFs need not belong to the sealed `Corpus.Manifest`; normal
acquisition and preserved source lineage remain mandatory.

## Preflight and authorization

Follow [deployment.md](deployment.md) for an independently authorized release.
Before operating, check the exact serving commit, migrations, private archive
readiness, worker roles, queue holds and existing source/extraction lineage.
Preserve existing queue holds. Neither this document nor the helper authorizes a
release, broad backfill, general queue drain, paid coverage, or status-flag edit.

Run `priv/ops/municipal_installations.exs` **only through authenticated release
RPC**. The RPC boundary supplies operator authorization; the helper uses the
configured review actor, not a caller-supplied identity. It is not a public
endpoint. It accepts only:

- `operation: :acquire | :preview | :publish` (required; no default operation).
- `communes: [...]` (required, nonempty, unique subset of `ixelles`, `uccle`,
  `forest`, `city-of-brussels`; no implicit all-communes scope).
- `max_facts_per_commune: 1..100` (required for `:publish` only).

Unexpected options fail closed. The following expressions are examples to run
inside the authenticated release, not shell commands that bypass authentication.

### 1. Acquire or reuse the exact approved evidence

```elixir
Code.eval_string(
  File.read!(Application.app_dir(:brussels_wtf, "priv/ops/municipal_installations.exs")),
  operation: :acquire,
  communes: ["ixelles", "uccle", "forest", "city-of-brussels"]
)
```

The helper calls `Acquisition.acquire(slugs, actor: reviewer)`. It prints only
`reused`, `queued`, and `failures` counts:

- **reused:** archived bytes and accepted native text were checksum-verified.
- **queued:** normal native extraction was requested; this is not readiness or
  publication. It may already be queued.
- **failures:** stop and inspect the private source/review diagnostics. Changed
  bytes, missing lineage, rejected native extraction or archive corruption must
  not be worked around by overriding hashes or forging locators.

Existing timestamps and immutable source versions are reused. Missing evidence
is fetched only through the pinned observed parent/leaf contract. Normal worker
jobs perform native extraction; the helper neither runs extraction itself nor
drains queues. The internal acquisition result includes source/job IDs for
private, authenticated diagnosis; the helper deliberately does not print them.
If a necessary queue is held, use the existing bounded job workflow with scoped
authorization for those jobs, not an unrestricted resume/drain. Rerun acquisition
after those jobs complete; require all selected documents reused and no failures
before proceeding. Four communes should yield eight ready PDFs.

**Exact PDF leaf policy (v1):** a PDF retrieval's final URL must equal its approved
source URL exactly. Even a same-origin redirect to another path or query is
rejected as `source_redirect_rejected`, is recorded as a failed observation, and
cannot queue extraction or count as ready. Reuse likewise requires at least one
successful exact-leaf observation for the pinned version; redirected-only history
is insufficient. Do not broaden verification or substitute an alias to bypass
this gate. Bounded same-origin redirects for parent **indexes** remain allowed
and retain their actual redirect history.

### 2. Preview privately, with count-only output

```elixir
Code.eval_string(
  File.read!(Application.app_dir(:brussels_wtf, "priv/ops/municipal_installations.exs")),
  operation: :preview,
  communes: ["ixelles", "uccle", "forest", "city-of-brussels"]
)
```

`MunicipalInstallation.preview/2` validates the retained evidence and produces
eligible source-ordered candidates without creating people or publishing facts.
Its direct result is private and can contain pending names. **Do not print that
result.** The helper emits only commune, eligible/excluded counts and a failure
boolean; it omits exception messages and candidate data. An eligible preview is
not a guarantee that identity resolution at publication will succeed.

### 3. First rollout: two per commune

```elixir
Code.eval_string(
  File.read!(Application.app_dir(:brussels_wtf, "priv/ops/municipal_installations.exs")),
  operation: :publish,
  communes: ["ixelles", "uccle", "forest", "city-of-brussels"],
  max_facts_per_commune: 2
)
```

This invokes `MunicipalInstallation.publish/2` through the trusted verifier. The
first rollout targets up to two source-ordered verified facts per commune (up to
eight total), not eight named people. Ambiguous identities can reduce the count;
never weaken the gate merely to fill a quota. Publication needs no individual
human approval once the source-specific gate passes.

**The cap is cumulative per commune, not an increment.** Repeating `2` converges
on the same first two admissible events; it does not publish the next two. After
readback, explicitly raise the cap (for example to `4`) to admit the next
source-ordered rows. The hard maximum is `100`. `published_existing` counts the
already-verified rows toward the cap; `published_new` counts new admissions.

The helper prints safe counts and public profile URLs only from a fresh verified
public projection after publication. Those URLs may include previously published
installations for the selected communes; they are not a list of newly created
people. No pending name, excerpt, object key, source-version ID, processing ID or
raw rejection message is printed. A failure can coexist with successful facts
from another commune: inspect counts, do not assume all-or-nothing publication.

## Readback and acceptance receipt

Before expanding the cumulative cap:

1. Confirm the helper's failure/rejection counts and verified fact counts. Repeat
   the same cap and confirm zero new publications and unchanged immutable source
   versions and prior verification history.
2. Open each returned profile in FR/NL/EN. Check the legal name, translated role,
   commune, dated-history section, **2024-12-01 installation and unknown end**, and
   official PDF page anchor. Do not label the installation “ended” merely because
   its start date is historical, and do not infer an end in 2030.
3. Confirm homepage discovery for every published role, selected-commune filters,
   stable profile/fact links, and useful mobile/no-JavaScript reading. Check that
   the legacy Calomne declared reporting period and Gazette state wording remain
   unchanged.
4. Confirm excluded/unverified candidates and private evidence fields are absent
   from anonymous HTML and that review/archive access remains authenticated.
5. Record actual release/image identity, counts, public URLs and test/readback
   results in an acceptance receipt. Keep private operational IDs and diagnostics
   outside public docs. This procedure alone is **not production completion**.

Correction, cessation and supersession for this lane remain follow-up work.
Never reuse installation provenance to verify an end date or correction. Do not
close all of issue #104's scope merely because the first bounded historical batch
passes its reader checks.

## Local verification

Worktree setup must already have completed. Use the isolated database partition:

```sh
MIX_TEST_PARTITION=issue104ui mise exec elixir@1.19.5-otp-28 erlang@28.1 -- \
  mix test test/brussels_wtf_web/municipal_installation_page_test.exs \
  test/brussels_wtf_web/municipal_installation_ops_test.exs \
  test/brussels_wtf_web/public_profile_page_test.exs
```

The route seam uses invented, privacy-safe source-shape fixtures through archive,
accepted native extraction, publication and real HTTP route rendering. Its test
transaction substitutes synthetic hashes only in the database's pinned-document
predicate; it does not change the production registry or mock PublicProjection.
The retained actual-PDF/backend contract suites remain separate evidence checks.
