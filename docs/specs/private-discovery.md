# Private municipal discovery — first general pass

## Authorized outcome

Discover private, source-backed mentions of people and organizations across Ixelles, Uccle, Forest and City of Brussels from 2024 onward. The operator authorized implementation and bounded production rollout, using one Codex subscription worker on lab and the existing capped OpenRouter allowance. This slice uses Codex only; it does not silently introduce a new paid fallback.

The user-approved principal seam is archived municipal text → queued analysis → lab worker → exact evidence validation → retained private candidates. These candidates are mentions, not resolved people or verified relationships. Public identity resolution, mandate/management/award verification, and broader source acquisition remain subsequent work. No manual per-person approval is introduced.

## Small implementation boundary

- An Ash-owned durable discovery job pins an accepted extraction run, its linked artifact and source version, source/meeting context, deterministic bounded lines, input hash and versioned extraction contract.
- Operator preview/enqueue/status/pause are domain functions behind reviewer authorization. Enqueue accepts an explicit bounded list of extraction-run IDs. A discovery batch identifier groups jobs; overlapping requests converge by a database identity on extraction run + chunk + contract. No broad polling or publication side effect.
- Accepted native/OCR text must be checksum-verified through the authoritative run/artifact link. Dates must come from municipal meeting/discovery context, not filenames or fetch dates. Only the four communes and dates >= 2024-01-01 are eligible.
- Exclude mandate declarations, Gazette and unknown supporting-document types initially. Minimize municipal public-session text before transfer; omit contact/private-ID/address/fiscal lines and private-session sections, with original line/page mapping. Exclusions are measured, not silently presented as complete coverage. Uncertain source eligibility fails closed.
- One configured lab worker claims one job at a time via narrowly scoped HTTPS bearer authentication. Production stores the token digest. This credential cannot fetch arbitrary archive objects, create batches, resolve identities or publish facts. Endpoints are disabled without configuration.
- Claims use expiring leases, bounded attempts and retry delays. A stale lease cannot commit; a identical result retry acknowledges existing completion. Conflicting results cannot overwrite evidence. Paused/failed jobs remain visible independently of transport jobs.
- Model output is strictly versioned JSON containing only input_hash and textual mentions (kind, text, line_id, quote). Validate exact keys, count/length limits, input hash and exact unambiguous quote/name presence in the pinned source line. Require exactly two unique, Unicode-word-bounded spans: the quote occurs once in the pinned line, and the name occurs once within that quote. The same name elsewhere on the line is allowed because the quote identifies the evidence occurrence. Duplicate `(line_id, text)` entries remain invalid, even with different quotes or kinds. Minimum lengths count Unicode code points (JSON Schema semantics); maximum lengths remain UTF-8 byte caps. Server-derived occurrence IDs and provenance prevent duplicate mentions. No fuzzy source matching.
- Retain result/provenance privately; no new Person, LegalEntity, SourcedFact, feed or public route is created by discovery. Discovery failure must not block ordinary meeting publication.

## Worker protocol v1

`POST /internal/discovery/claim` with `{}` returns 204 when idle, or JSON:

```
{"id":"uuid","lease_token":"opaque","lease_expires_at":"ISO8601",
 "input":{"schema_version":"municipal-mentions-v1","input_hash":"sha256",
          "lines":[{"id":"p1-l1","text":"exact minimized line"}]},
 "schema":{...JSON Schema...}}
```

`POST /internal/discovery/:id/result` accepts:

```
{"lease_token":"opaque", "result":{"schema_version":"municipal-mentions-v1",
 "input_hash":"sha256","mentions":[{"kind":"person","text":"Exact Name",
 "line_id":"p1-l1","quote":"Exact supporting text"}]},
 "processor":{"name":"codex-cli","version":"0.155.0","model":"actual configured model"}}
```

It returns a sanitized acknowledgment, with identical replay accepted. `POST /internal/discovery/:id/fail` accepts lease_token and reason from `quota`, `unavailable`, `invalid_output`, `timeout`. No arbitrary diagnostic bodies. Lease duration 15 minutes, worker execution timeout at most 5 minutes, at most three executions per job; quota pauses processing rather than spending through another provider. Claim serializes globally for this one-worker slice.

## Lab isolation

The Python standard-library worker owns the machine credential outside the Codex process. Codex runs in a disposable, non-root, resource-limited Docker container with only its subscription authentication, input and schema. No production DB credentials, host repository, home directory, Docker socket, inherited user hooks/MCP or machine token inside. Use supported `codex exec`, ephemeral sessions, ignored user config, read-only sandbox, no shell tools, explicit output schema, wall timeout and bounded output. Treat source text as data, never as executable instructions. Only sanitized status/counts go to logs. Worker retries submission from a mode-0600 spool before claiming more work; a local lock prevents duplicate service instances.

## Acceptance

Tests at the agreed source→private-candidate seam cover four-commune eligibility, native/OCR lineage, checksum failures, exact French/Dutch/Unicode spans, rejected invented/private output, replay/conflict, lease expiry, one concurrent claim, scoped machine auth, and unchanged public identities/facts. Worker tests exercise the same job protocol through a local controlled server and controllable subprocess, including restart after inference and quota stop. Run a bounded real-source/Codex smoke before claiming activation. Report built, tested and actually deployed outcomes separately.

## Lab verification receipts — 2026-09-20

One accepted native-text chunk from a hash-pinned real PDF per commune reached backend-validated private mentions using Codex CLI 0.155.0 and explicitly configured model `gpt-5.6-sol`:

| Commune | Accepted mentions | Input tokens | Output tokens | Receipt stage |
| --- | ---: | ---: | ---: | --- |
| Ixelles | 25 | 9805 | 1814 | Final authorized single-call smoke; agreed two-span rule |
| Uccle | 20 | 9607 | 1248 | Preceding prompt revision |
| Forest | 49 | 9314 | 1716 | Initial smoke |
| City of Brussels | 19 | 9591 | 803 | Initial smoke |

These are accumulated receipts across bounded runs, not a fresh four-job run under an identical prompt/image. All four sources passed native quality. Accepted paths preserved protected Person, LegalEntity, SourcedFact and publication counts; mentions remained unresolved/private. Other chunks were paused and test database changes rolled back. This proves the bounded real-source seam, not extraction completeness, recall, throughput, or production activation.

The diagnostic Ixelles capture contained 26 candidates. The former third uniqueness check rejected indexes 16 and 19 because a name repeated outside its uniquely identifying quote. After the agreed rule correction, the **unchanged** capture passed both Python and backend validation with all 26 candidates: none was repaired or discarded. The private capture and its directory were deleted after offline verification; only synthetic regression data and sanitized counts remain in the repository.

The final `discovery-codex:0.155.0` image was rebuilt as `sha256:966a7dbd6d08625d50013d7bc2ea421a47e0fbb917cd0fe64244dfdff46376bc` before the last Ixelles call. That authorization consumed exactly one call, with the explicit Ixelles-only filter and no retry/fallback; no other communes were called again. There has been **no deployment or service activation** as part of this verification.
