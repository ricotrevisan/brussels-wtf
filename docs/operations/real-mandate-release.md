# First real mandate release

Delivery: [Publish one Brussels public mandate end to end](https://github.com/ricotrevisan/brussels-wtf/issues/46).
This is a bounded release/publication procedure, not a record of deployment.

## Reconciled baseline — 2026-09-15

- `origin/main`: `f989249aa779b3f726be90578dfba1caca18997c`, including merged
  [PR 90](https://github.com/ricotrevisan/brussels-wtf/pull/90).
  [Main CI passed](https://github.com/ricotrevisan/brussels-wtf/actions/runs/34770901915).
- `https://brussels.wtf/health/version` returned
  `2de29bf10dc8bef15553c9d891ae60068d69555e`. The browser homepage showed existing
  municipal coverage but no mandate discovery section or person links.
- The retained actual PDFs/OCR passed 28 isolated tests, including the real
  acquisition → identity → verification → FR/NL/EN browser journey. This does
  not establish a production fact or production OCR run.
- A production-only packaging failure was reproduced: `LazyHTML.from_document/1`
  was unavailable because the parser dependency was restricted to `:test`.
  The dependency must ship at runtime; the runner image now exercises its native
  parser as a build gate. Test-environment success alone missed this failure.
- The personal Loggie catalog did not expose Coolify. Rico subsequently
  explicitly authorized the Mochary connection for this project. Use that
  recorded account override for Coolify; existing `rico@coolify` SSH provides
  runtime inspection. Keep credentials and retained source bytes private.

## Production readback — 2026-09-16

- App and OCR now serve the same `22c1613ba721c518e36c7236f6dfb212bda15443`
  image, digest `sha256:f3e4d20bd49b580402107d2fc0e193630dc5a312a7311bc47ebb629afdb5cecc`.
  App readiness and repeated OCR readiness passed. OCR remains one CPU/1 GiB.
  The inspected queues were idle and unpaused; there was no pending backlog.
- Both accepted PDFs were already retained, with matching archive checksums.
  The independent identity source passes `trusted_ixelles_identity_source`.
  The retained declaration OCR matches the inspected profile and parser.
  Reuse this lineage; a new download is unnecessary.
- Bounded candidate discovery created one unreviewed Gautier Calomne mandate.
  Two ordinary verifier jobs rejected it; no public fact was accepted.
  A diagnostic traced the cause to the default 15-second database transaction
  deadline while independent OCR took about 21 seconds. Enclosing test
  transactions hid the problem. The regression uses a disposable database,
  ordinary connections and delayed OCR to reproduce the unpublished fact.
- The verifier fix allows the configured OCR wall-time budget plus 60 seconds
  for archive, metadata, cleanup and database work. Source, identity, byte,
  privacy and publication checks remain mandatory. Deploy the reviewed fix to
  both roles, then retry only the existing eligible fact through the normal
  OCR worker and complete reader acceptance below.
- CBE release directory and digest are absent at runtime. Existing KBO login
  credentials do not activate the full-release adapter; this remains separate
  from the standalone mandate journey.

The rollout from the observed release also includes already merged Gazette
projection and registered-feed changes (PRs 85–88 and the individual-unfollow
change). Include that complete diff in release review. Gazette acquisition remains
excluded under the [source register](https://github.com/ricotrevisan/brussels-wtf/issues/57).

## Release prerequisites

Follow [deployment.md](deployment.md): merge the reviewed packaging fix only with
scoped consent, then build the clean, exact merged commit with `SOURCE_COMMIT`.
Run main CI, precommit, both review axes, and both production-image contract suites.
After merge, rebuild rather than relabel a pre-merge image.

Before requesting the bounded publication approval, use read-only runtime RPC to
record:

1. Serving app/OCR image digests, release SHA, process roles, OCR health, one CPU
   and 1 GiB limits, and live Oban queue `paused`, `limit`, and `running` values.
2. Existing `normalize`/`publish` holds and queued work. Preserve holds across
   rollout; inspect startup consumers before any processing can drain old work.
   A release approval must name any required hold restoration. Do not infer
   permission to resume or drain a queue from permission to acquire one document.
3. Exactly one Ixelles source version satisfying this read-only query:

   ```sql
   SELECT v.id, v.sha256, v.byte_size,
          trusted_ixelles_identity_source(v, r) AS identity_context_valid
   FROM source_versions v
   JOIN source_records r ON r.id = v.source_record_id
   WHERE r.origin_url = 'https://www.ixelles.be/uploads/conseil/pv/267.pdf'
     AND v.sha256 = '4ac4ed359acbc2d6f245226657f8a43e533281d533b3f16e1a3701ec97db87e5';
   ```

   Require `1669707` bytes and `identity_context_valid=true`, then checksum the
   actual private object through `BrusselsWtf.Archive.get/1` without printing
   bytes or object keys. Inspect locator/retrieval lineage if this fails. Reuse
   the exact existing source; do not invent an identifier or substitute a fixture.
   The function is introduced by the mandate release, so this final query runs
   after its migrations. Before rollout inspect equivalent source/locator lineage.
4. Existing declaration versions, people with the exact name, sourced facts and
   OCR/verification jobs. An existing eligible fact should be accepted through
   the public journey instead of acquiring it again. Ambiguous identities remain
   unresolved. Record IDs privately for the bounded action and readback.

Roll out `app`, then the identical image to `ocr`, preserving the limits and
holds above. Require `/health/ready` 204 and `/health/version` equal to the exact
merged commit, both matching image digests, and sustained OCR readiness.

## One authorized acquisition

The previously recorded Ixelles permission already covers the source use. The
remaining scoped authorization is operational release and one publication run.
No new correspondence is needed.

On the running app release, create one `Ingestion.start_poll_run!` record with
`requester_id` set to the authenticated operator's actor ID,
`started_at: BrusselsWtf.Clock.utc_now()`, `kind: :poll_now`, `target_type: :index`,
the Ixelles commune ID, `target_id: MandateDeclaration.index()`, a fresh unique
check key, `scope: :current`, and `status: :running`. Retain its ID before I/O.
Do not call `request_poll_now!` for the commune: that would schedule a broader poll.

Invoke only:

```elixir
BrusselsWtf.Identity.IxellesMandateDeclarationProcessor.acquire(ixelles_id, poll_run.id)
```

This retrieves the official index and its approved `mandats-2024.pdf` link,
retains immutable evidence, and queues normal extraction. Require the declaration
checksum `c5b717d6243bd8ad3957f486ca9408a153c636927314642d03ec50e4505fbca2`
and 5,206,831 bytes. New bytes require a fresh inspected contract.
Record poll completion or failure with the existing named poll-run actions after
inspecting observations; an `:ok` return alone does not prove publication.

Allow only this source's native extraction and the normal isolated OCR/verifier
work. The inspected OCR profile selects pages 14 and 17, `fra+nld`, force-OCR,
page segmentation mode 6, concurrency one. If a necessary queue is held, prepare
the exact job IDs and bounded operation for approval; never resume the entire
backlog. Preserve private raw/OCR artifacts and processing provenance.

Require one verified `ixelles_mandate_declaration_v3` fact with its real source,
successful processor/artifact lineage and corroborated person. No manual
verification flag, contract override, synthetic seed, or paid generation is part
of this operation. On uncertainty, retain the review case and stop publication.

## Reader acceptance and idempotency

Use the returned actual person/fact IDs with the existing browser acceptance:

```sh
uv run --project test/browser --frozen python test/browser/mandate_declaration.py \
  --base https://brussels.wtf --person "$PERSON_ID" --fact "$FACT_ID" \
  --name 'Gautier Calomne' --source-page 14
```

It checks homepage discovery, exact fact anchors and official page-14 citations,
FR/NL/EN, 1280px/390px reading, and excluded private fields. Also switch languages
using the visible controls, check selected-commune filtering, and verify the
December 1–31, 2024 fact is in dated history. June 2026 identity evidence creates
no new appointment and never extends that period.

Load the exact verified fact ID first, then call
`IxellesMandateDeclarationProcessor.process(fact.id)` through the normal bounded
action; require unchanged fact/source-version counts and preserved evidence
history. This checks the verified-fact no-op; isolated integration tests cover
full acquisition/processing replay. A processing-run ID is not a fact ID, and a
successful return for an unknown ID proves nothing.
Verify anonymous review/artifact requests cannot expose private evidence. Record
actual live URLs, release/image IDs, poll/processing IDs and checksums in the
acceptance receipt before closing the issue. Keep source bytes and operational
IDs that expose private context outside Git.

If release fails, follow the compatible-image rollback procedure in
[deployment.md](deployment.md#rollback). Never roll migrations down to remove
facts or erase retained history.
