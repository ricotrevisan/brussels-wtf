# Domain glossary

## Commune

One of the municipal authorities covered by the publication. The initial scope is Ixelles, Uccle, Forest, and the City of Brussels (1000 Brussels).

## Council meeting

A scheduled session of a commune's municipal council. A meeting may have multiple published versions of its agenda and multiple source records before and after it occurs.

## Source record

An item obtained from an authoritative publisher, such as an agenda, addendum, supporting dossier, minutes, voting record, decision, livestream, or recording. A source record retains its origin and publication time. Archived file copies are private evidence; public coverage links to the authoritative origin and may expose its checksum and retrieval time.

## Source locator

An exact URL discovered by a commune adapter together with its parent index and meeting context. A locator can change what bytes it serves and is never itself a version identity.

## Retrieval observation

A record of one attempted or successful check of a source locator, including unchanged responses, redirects, response metadata, and disappearance from an index.

## Source version

An immutable byte snapshot of a source record identified by its SHA-256 hash and private rustFS object key. New bytes at an existing locator create a new source version and never overwrite history.

## Processing run

One execution of a named, versioned processor and configuration against a source version. It records inputs, outputs, quality measurements, timing, and failure details.

## Derived artifact

An immutable processor output such as extracted text, OCR text, normalized structure, or a transcript. It retains its input hash, processor provenance, output hash, and private object key.

## Publication input

A deterministic projection of the current normalized meeting, its publishable claims, and their official evidence. Content generation may use only this projection; its hash identifies the exact generation being gated.

## Coverage run

One immutable execution of canonical French generation or Dutch/English translation for a meeting page. It retains its publication-input or parent-output hash, processor provenance, output hash, timing, usage, and failure details. Translation runs identify their canonical French parent.

## Generated claim reference

A stable reference from generated coverage to a claim present in the publication input. References do not create facts; unknown or unsupported references fail the publication gate.

## Review case

An actionable acquisition, extraction, normalization, or evidence ambiguity that requires Rico's attention. It is domain work, not merely a failed background job, and resolving it never mutates raw source versions.

## Agenda

A versioned list of agenda items for exactly one council meeting. Base agendas, supplements, addenda, and corrected files are separate source records describing versions of that meeting's agenda.

## Agenda item

A numbered matter scheduled for discussion or decision at exactly one council meeting. It is a meeting-specific occurrence: its wording, position, evidence, and outcome belong to that meeting. A supplement that changes an authoritatively identified item creates another version of the same agenda item; a newly added matter creates a separate agenda item.

## Dossier

A continuing real-world matter that may appear as different agenda items across multiple meetings and communes. A dossier has a public timeline page. Dossiers can be merged or split without erasing history; retired dossier URLs redirect to the surviving dossier.

## Dossier link

A many-to-many connection between an agenda item and a dossier. An authoritative identifier or high-confidence automated match may create the link directly. A medium-confidence match creates a separate dossier and an internal merge suggestion. Every automated link retains its matching provenance.

## Link correction report

A public report that a dossier link is incorrect. A report creates an editorial review item rather than removing the link automatically. Rico can confirm or remove the link, and the decision prevents the matcher from repeating a rejected association.

## Proposal

The action described before the council has made its final decision. A proposal is never presented as an adopted decision.

## Decision

The council's documented final disposition of an agenda item, including approval, rejection, amendment, postponement, withdrawal, or another explicitly sourced outcome. A later meeting that changes an earlier decision produces a new decision linked through the dossier; it never rewrites the historical decision. Until an authoritative final record appears, the agenda item's outcome remains unknown.

## Meeting page

The publication unit for one council meeting. It contains individually addressable coverage items and moves as a whole between `draft` and `published`. Upcoming coverage and later final outcomes update the same page while preserving dated revisions.

## Publication revision

An immutable dated snapshot of one complete meeting-page publication. It records the exact canonical and translated coverage runs plus the rendered content, so replacing the current variants never erases what readers previously saw or the evidence input retained by those runs.

## Coverage item

A public explanation of one agenda item within a meeting page. It states whether the underlying material is a proposal or final decision and may link to a continuing dossier.

## Locale variant

The French, Dutch, or English representation of the same meeting page, coverage item, or dossier. French is the canonical editorial text for the MVP, while source evidence may be French, Dutch, or bilingual. All three locale variants publish together. Factual corrections update all three in one revision; typography-only corrections may affect one locale.

## Content provenance

Public metadata describing how text was produced or reviewed. The MVP uses `AI-generated`, `machine-translated`, and `human-reviewed` when each is true. Official sourcing is mandatory baseline behavior exposed through citations, not a provenance badge. Content provenance does not change the underlying source evidence or publication status.

## Localized URL

A permanent resource URL using a stable identity and optional BCP 47 language query, such as `/meetings/{id}?lang=nl-be`. Language resolution precedence is an explicit valid `lang`, the reader's persisted selection, the browser's `Accept-Language` preference on first visit, then English. The path remains identical across languages.

## Mention

A reference to a person or organization within a source record. A mention does not by itself establish identity, involvement, ownership, or a relationship. Unresolved company enrichment does not block meeting-page publication; verified facts update the page when later discovered.

## Legal entity

A formally registered organization identified by its CBE enterprise number. Establishment units and trading names belong to the legal entity; name matching alone never creates one.

## Person

A natural person whose identity is supported by an explicit identifier or an exact name plus at least one corroborating fact such as municipality, dated mandate, organization, or role. Ambiguous matches remain separate. Every person with a publishable sourced role may have a public page, including company managers. Public profiles expose legal name, sourced roles, public mandates, relevant council mentions, and a dated timeline; they never expose private addresses, signatures, contact details, identity numbers, or family information.

## Role

A sourced position held by a person or legal entity, such as council member, director, manager, beneficial owner, shareholder, contractor, or office holder. A role may have effective dates.

## Relationship claim

A typed, time-bounded assertion such as a management role, ownership, council mandate, contract, donation, or declared interest. Broad company/councillor connections are derived from verified underlying facts rather than stored as vague edges. Every publishable relationship carries evidence, effective dates when known, and a verification status. New evidence closes or supersedes current status without erasing historical roles. Management never implies ownership.

## Ownership suggestion

A public open-ended text submission proposing missing ownership information. It requires no account, accepts optional private contact information, and is protected by basic rate limiting and a honeypot. It remains private until Rico approves it; approval creates the publishable relationship and rejection is retained to prevent repetition.

## Correction suggestion

A public open-ended text submission from a company or person page. It follows the same private review workflow as an ownership suggestion. Approved identity merges, profile corrections, and relationship changes retain audit history and redirect retired duplicate profiles.

## Evidence

A source-backed record supporting or contradicting a factual claim. Evidence identifies its source, relevant excerpt or location, retrieval time, and applicable time period.

## Verification status

The evidentiary state of a claim: unreviewed, verified, rejected, or superseded. This is separate from publication status. Model inference and name similarity remain unreviewed signals and are not publishable facts.

## Publication status

Whether a meeting page is `draft` or `published`. A draft publishes automatically when all three locale variants exist and its evidence requirements pass. Editing or correcting a published page does not add another publication status; revisions preserve its history. Moving a published page back to `draft` hides its content but leaves a public withdrawal notice at the existing URLs.

## Publication gate

The automated checks required to move content from `draft` to `published`. The gate requires complete FR/NL/EN locale variants, claim-specific official evidence, and applicable provenance labels. Rico Trevisan may review or edit content but his approval is not required for publication. Public coverage carries his byline.

### PDF extraction and OCR

- A **native extraction generation** always runs Poppler first and retains page-level quality decisions and a private `native-text` derived artifact.
- An **OCR generation** is created only for rejected native pages. It uses the isolated concurrency-one OCR role with `fra+nld` and retains separate `ocr-pdf` and `ocr-text` artifacts.
- A **processing-run artifact link** preserves every authoritative processing generation even when identical content-addressed artifact bytes are shared by more than one source origin.
- Normalization consumes exactly one accepted, checksum-verified text artifact. Processor output maps are summaries, not an alternate evidence store.
- Automatic transcription remains disabled and requires a separately accepted bilingual benchmark before it can be enabled.
