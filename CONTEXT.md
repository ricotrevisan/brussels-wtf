# Domain glossary

## Commune

One of the municipal authorities covered by the publication. The initial scope is Ixelles, Uccle, Forest, and the City of Brussels (1000 Brussels).

## Council meeting

A scheduled session of a commune's municipal council. A meeting may have multiple published versions of its agenda and multiple source records before and after it occurs.

## Source record

An item obtained from an authoritative publisher, such as an agenda, addendum, supporting dossier, minutes, voting record, decision, livestream, or recording. A source record retains its origin and publication time. Archived file copies are private evidence; public coverage links to the authoritative origin and may expose its checksum and retrieval time.

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

## Coverage item

A public explanation of one agenda item within a meeting page. It states whether the underlying material is a proposal or final decision and may link to a continuing dossier.

## Mention

A reference to a person or organization within a source record. A mention does not by itself establish identity, involvement, ownership, or a relationship.

## Legal entity

A formally registered organization identified through authoritative registry evidence. A trading name or textual mention may remain unresolved until it can be linked reliably to a legal entity.

## Person

A natural person whose identity is supported by sufficient evidence. Sharing a name with another record is not sufficient identity evidence.

## Role

A sourced position held by a person or legal entity, such as council member, director, manager, beneficial owner, shareholder, contractor, or office holder. A role may have effective dates.

## Relationship claim

An assertion connecting people, legal entities, communes, agenda items, contracts, or roles. Every publishable relationship claim carries evidence, effective dates when known, and a verification status.

## Evidence

A source-backed record supporting or contradicting a factual claim. Evidence identifies its source, relevant excerpt or location, retrieval time, and applicable time period.

## Verification status

The evidentiary state of a claim: unreviewed, verified, rejected, or superseded. This is separate from publication status. Model inference and name similarity remain unreviewed signals and are not publishable facts.

## Publication status

Whether a meeting page is `draft` or `published`. Editing or correcting a published page does not add another publication status; revisions preserve its history. Moving a published page back to `draft` hides its content but leaves a public withdrawal notice at the existing URLs.

## Editorial approval

Rico Trevisan's decision to move a coverage item from `draft` to `published`. Company ownership, management, and council-member connections always require editorial approval.
