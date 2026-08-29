# ADR 0004: Automate evidence-gated relationship publication

- Status: accepted
- Date: 2026-08-29
- Decision issue: https://github.com/RicoTrevisan/brussels-wtf/issues/30

## Context

Requiring Belgian counsel review and Rico's personal verification before every company/person relationship publication prevents the site from accumulating routine facts from authoritative public records. Removing those approvals must not turn names, mentions, model output, management roles, tender notices, or unsupported identifiers into published relationships.

## Decision

Public company/person facts may publish without prior counsel sign-off or human approval after a trusted source-specific processor marks them `verified`. That transition requires resolved subject and object identities, direct authoritative evidence, typed neutral semantics, and the applicable evidence rules. `human-reviewed` remains optional provenance and never follows from queue authorization alone. Private fields, ambiguous identities, inferred relationships, UBO data without established access and republication rights, and public suggestions remain fail-closed.

## Consequences

[Obtain Belgian media and privacy legal review before launch](https://github.com/RicoTrevisan/brussels-wtf/issues/12) no longer blocks relationship implementation. [Add private CBE entity resolution and enrichment](https://github.com/RicoTrevisan/brussels-wtf/issues/29) remains a private candidate-fact foundation; it does not make facts public. [Enable evidence-gated profiles, relationships, and suggestions](https://github.com/RicoTrevisan/brussels-wtf/issues/30) must add the trusted verifier registry, one-way audited verification transition, current-fact/supersession rules, safe projections, and public-route acceptance seam before any relationship content appears. Later policy or counsel advice may tighten those rules without reintroducing a blanket approval state.
