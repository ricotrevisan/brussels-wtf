# ADR 0002: Timeline-first public and review interface

- Status: accepted
- Date: 2026-08-11
- Decision issue: https://github.com/RicoTrevisan/brussels-wtf/issues/10
- Prototype branch: https://github.com/RicoTrevisan/brussels-wtf/tree/prototype/ui-shell/prototypes/ui

## Context

The MVP needs a compact public reading experience across four communes and a small internal interface for ingestion, evidence, and correction exceptions. A throwaway static prototype compared ledger, briefing, and timeline presentations against the settled meeting, dossier, publication, language, and provenance rules.

## Decision

Use the **timeline** variant as the public interface direction.

### Public homepage

- Lead with latest and upcoming council coverage across all selected communes.
- Keep `Coming up` and `What they decided` as separate sections so proposals are never confused with final outcomes.
- Use a dense, text-first civic timeline with minimal imagery.
- Remember selected communes in the browser; first-time readers see all four.
- Show municipality, meeting date, agenda-item number, factual summary, proposal/decision status, applicable provenance labels, evidence citations, and links to dossiers, companies, and people.
- Open feed entries at an agenda-item anchor inside the meeting page rather than creating a separate article route.
- Keep language in the optional `lang` query parameter under the stable resource URL rules in `CONTEXT.md`.

### Review interface

Use a review inbox that opens a source-versus-extracted-text detail view. Each case exposes immutable source/version context, the affected normalized content, reviewer notes, and explicit retry, reclassify, relink, correction, or unsupported actions. Review cases remain separate from background-job transport state.

### Suggestions and corrections

Public dossier links can be reported as incorrect. Person and company pages expose open-ended ownership and correction suggestions. Submissions enter the private review inbox; they do not mutate published facts directly.

## Consequences

- The production interface has one chosen direction rather than carrying a theme selector.
- The prototype remains on its throwaway branch as the primary source; production code should reproduce validated behavior, not copy the static implementation blindly.
- Ledger and briefing variants are rejected for the MVP but remain available on the prototype branch for comparison.
- Authentication, exact responsive behavior, and implementation components remain implementation-ticket concerns.
