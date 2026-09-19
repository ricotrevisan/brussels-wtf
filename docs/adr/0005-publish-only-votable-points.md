# ADR 0005: Publish only the votable points of a council meeting

- Status: accepted
- Date: 2026-09-18
- Decision issue: https://github.com/RicoTrevisan/brussels-wtf/issues/98

## Context

Every real council agenda contains non-votable points: information items, interpellations,
communications, and announcements such as "Information au Conseil communal des décisions
prises par le Collège". Normalization keeps those points as agenda items, but they describe
no proposal and no decision, so they carry no claim with official evidence.

The publication input previously projected every agenda item. The publication gate requires
at least one claim per item and an accepted procedural state and outcome per item, so one
information point failed the whole page:

- Ixelles 266 normalized 33 proposal items plus one information item.
- Publication failed with `unsupported_publication_state` and `missing_claim` for that item.
- Meeting 265 has 13 such items and meeting 262 has 16.

With that rule, no new meeting could publish, because information points are normal.

## Decision

The publication input is the publishable set. An item is publishable when it carries at
least one current (non-synthetic) proposal claim or the current non-synthetic decision.

An item that asserts a terminal decision outcome (`approved`, `rejected`, `amended`,
`postponed`, `withdrawn`, `other`) or a `decision` procedural state is publishable even
when no decision record exists. That inconsistency must fail loudly: the gate reports
`unsupported_publication_state` and `missing_decision_claim` for the item instead of
silently omitting it. Only items that assert nothing publishable are excluded: no current
claims, a non-decision procedural state, and an unknown outcome.

An excluded item neither blocks the publication gate nor reaches coverage generation. The
stored meeting record keeps every agenda item, and the review inbox still sees it.

The publication path narrows to the same publishable set when it writes coverage variants
and when it evaluates the gate. A meeting whose publishable set is empty still fails closed
with the existing `missing_item` error. `validate/1` semantics are unchanged for every
included item: official evidence, claim kind, decision outcome, and procedural state still
fail closed, and no failure code was removed or weakened.

A public meeting page therefore covers the votable points. Non-votable points stay in the
meeting record and are not summarized: they have no claim that could be cited, and the
product never presents unsupported prose. This is recorded plainly here and in
`docs/operations/publication.md` so no reader has to infer why an agenda item is absent
from a public page. The stored revision still references the exact evidence input that
produced it.

## Mechanism

The projection alone is not the whole mechanism. Filtering `PublicationInput.build/1` was
not sufficient, because three other seams still iterate `meeting.agenda_items`:

1. `BrusselsWtf.Council.Publication.persist_variants/3` upserts one coverage variant per
   meeting item. For an item that generation never produced, that upsert passes a nil title
   and the transaction fails with an Ash `attribute title is required` error.
2. `BrusselsWtf.Council.PublicationGate` requires all three locale variants for every
   meeting item, so an item outside the projection produces `missing_coverage_variant` and
   the whole page fails.
3. `BrusselsWtf.Council.PublicationRevision.valid_for_publish?/4` compares the stored
   revision content with `public_content/2` built from the restored scope. An item outside
   the projection makes them differ, and publication fails with "publication gate and
   matching revision are required".

`PublicationInput.scope_meeting/2` therefore returns a loaded meeting narrowed to the keys
of a built input, and `BrusselsWtf.Council.PublicationScope` applies it in
`for_batch!/2` (the unscoped and empty-scope branches) and in `selection/2` (the unscoped
branch). Those are the two entry points that feed variant persistence, the gate, and the
revision-content check.

`PublicationScope.restore/2` deliberately keeps `current_input = PublicationInput.build(meeting)`
computed from the full meeting for an unscoped input, while narrowing only the returned
meeting struct. The input stays the complete current projection, so
`PublicationLifecycle.republish!` and `Publication.publish_revision/6` still detect a newly
normalized publishable item as stale. Narrowing the input there would hide exactly the
change those checks exist to find.

## Consequences

- Existing recorded corpus meetings keep byte-identical publication inputs, because every
  sealed item carries a claim. Published pages and their stored input hashes are unaffected.
- A newly normalized publishable item still makes a withdrawn or published revision stale.
- A claim-less non-votable item (no current claims, non-decision procedural state, unknown
  outcome) never marks published content stale, and no path can change public content
  because of it. Such an item is outside the projection, so it contributes no item to the
  coverage bundle, no claim reference, and no locale variant;
  `GenerationContract.validate_bundle/3` requires the generated item keys to equal the
  input item keys, and a republication reuses the stored revision content. The page can
  therefore only stay the same or fail the gate, never gain an unreviewed section. The one
  exception is a claim-less item that asserts a terminal decision outcome: it stays in the
  projection, so it marks content stale or fails the gate as described below.
- An explicit coverage scope that names an item without claims fails closed with
  `invalid_publication_scope` rather than silently covering it.
- A terminal decision outcome without its decision record keeps the item in the publishable
  set and fails the gate with `unsupported_publication_state` and `missing_decision_claim`:
  a missing decision is an error to fix, not an item to drop.
