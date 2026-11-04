# ADR 0006: Publish resolved minutes points while others stay unknown

- Status: accepted
- Date: 2026-11-03
- Decision issue: https://github.com/RicoTrevisan/brussels-wtf/issues/147

## Context

An open normalization case on a source record linked to a meeting blocks that meeting's
publication. Real Ixelles minutes retitle or renumber a few points of a meeting. The
normalizer rightly refuses those points, so if each refusal blocked the page, one retitled
point in 72 would hold back every documented decision of that meeting.

## Decision

A successful minutes reading publishes the points it resolved. Points it could not resolve
keep an unknown outcome and are listed, with printed identifier and reason, in one open
normalization case classified `minutes_items_unmatched`. That one classification does not
block the publication gate. Every other open normalization or evidence case still blocks.

A document whose identity or structure cannot be verified is not partial: it records
nothing and its ambiguity case stays as before, on a source record still unlinked to the
meeting.

## Consequences

- The published page says "unknown" for a refused point. That is exactly what the evidence
  supports, so the non-blocking case cannot make the page assert anything unsupported.
- A successful reading resolves earlier cases on the same source version. Otherwise linking
  the minutes to the meeting would turn an old `processor_unavailable` case into a block.
- The case stays in the review inbox until a reader resolves it or a later reading changes
  the unmatched list.
