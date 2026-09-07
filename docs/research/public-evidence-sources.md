# Public evidence sources after Ixelles minutes

_Status: research note for [issue #36](https://github.com/rico/brussels-wtf/issues/36), not a domain decision. Checked 2026-08-31. UBO data is intentionally excluded._

## Recommendation

The safest next public claim is a **company management appointment or cessation published in the Belgian Official Gazette annexes**, with CBE Open Data as the legal-entity spine. Next, add **Brussels public-mandate declarations** from the responsible authority. Add **procurement awards** only from a result/award notice, preferably TED, and never from a competition/tender notice.

| Priority | Official evidence | Publishable typed claim | Public link policy |
|---|---|---|---|
| 1 | Belgian Official Gazette, legal-person annex | `management_role_started`, `management_role_ended` (and the source's exact role) | Link to the exact e-Justice publication; quote only the minimal supporting excerpt until reuse terms are confirmed |
| 2 | Municipality/Brussels Parliament transparency publication | `public_mandate_held` for the declared reporting period; optionally a separately typed remuneration band if explicitly published | Link to the exact authority page/document and retain reporting year |
| 3 | TED result/award notice | `public_contract_awarded` between the named buyer and winner, for the stated lot, result and value basis | Link to the exact TED notice/version; TED expressly permits reuse subject to stated exceptions |
| Supporting spine | CBE Open Data | `legal_entity_registered`, registered name/status/form, and a CBE legal-function claim only where the licensed Open Data field explicitly supplies it | Do not scrape or republish Public Search; use the separately licensed Open Data product |

This ordering is based on semantic and operational safety, not on an assertion that every source has already been integrated.

## 1. CBE: identity spine, not a generic evidence oracle

The FPS Economy says CBE Public Search exposes public entity and establishment data, including enterprise number, status, legal form, names, dates, and people exercising a legal function. It also says the data appear the day after entry/change. Crucially, the same page prohibits reuse of Public Search data and systematic continuous downloading. Bulk use must therefore come from **CBE Open Data under its own licence**, not from Public Search scraping.[^cbe-search] The FPS publishes the applicable Open Data conditions separately.[^cbe-licence]

**Access and reuse.** CBE Open Data requires registration and acceptance of its licence. Before production, record the accepted licence version and confirm that the intended public fields, update frequency, attribution, and downstream display comply with it. Public Search can be a human verification link, but is not an ingestion or republication licence.

**Identity rule.** A Belgian legal entity resolves only by normalized ten-digit CBE enterprise number (including check-digit validation), not by name, address, or establishment-unit number. Preserve redirects/duplicate-number handling: FPS Economy says a closed duplicate search redirects to the retained number.[^cbe-search] A natural person in a CBE function does not automatically resolve to an existing person: require exact legal name plus one independent corroborator under `CONTEXT.md`, or keep a separate unresolved mention.

**Semantic limit.** A CBE “legal function” means only the coded function supplied by CBE. It must not be widened to owner, shareholder, beneficial owner, decision-maker, or contractor. Current status must not be used to invent a historical start/end date.

**Fail closed.** Reject publication when the enterprise number is absent/invalid, the dataset/licence version is unknown, the field is not part of the licensed product, the function code is unmapped, dates conflict, or a person match relies only on a name. Never treat a CBE external link as evidence of the linked claim; verify the target source separately.

## 2. Belgian Official Gazette legal-person annexes

The official e-Justice annex search exposes publications by enterprise/VAT number and provides publication records for legal persons.[^gazette-search] CBE Public Search itself links to Belgian Official Gazette publications, making enterprise number the stable bridge rather than company name.[^cbe-search]

**Suitable claims.** Publish only the operative facts explicitly stated by the act: appointment, reappointment, resignation/dismissal or end of a named director/manager/administrator/liquidator (using the source's exact legal role), with the stated decision/effective date. The publication date is source metadata, not necessarily the role's effective date.

**Access and reuse.** Exact records are publicly linkable through e-Justice. I did not find a clear first-party bulk API or a source-specific reuse licence for legal-person annex content during this review. Therefore the safe initial policy is link-first, private evidentiary snapshot, checksum/retrieval time, and only a minimal necessary excerpt. Bulk republication or mirroring remains blocked pending written/licence confirmation. This uncertainty does not affect linking to the official record.

**Identity rule.** Require the Gazette record itself to carry the same CBE enterprise number as the legal entity. Resolve the person only when the publication provides an exact name and the project has an explicit identifier or the required corroborating fact. Do not use address, signature, or name similarity as the corroborator displayed to readers.

**Semantic limit.** An appointment proves a management/governance role only. It proves neither shares nor beneficial ownership. An incorporation act is not evidence that a named person remains in office today; later publications can close or supersede the role.

**Fail closed.** The verifier must be specific to the act subtype and language/layout. It must reject missing/mismatched enterprise number, OCR-only uncertainty, ambiguous role verbs, merely proposed appointments, absent effective date when the claim requires one, and unexplained conflict with a later act. Corrections and later cessations supersede status without deleting history.

## 3. Brussels public-mandate transparency publications

The Brussels Parliament explains that the joint ordinance of 14 December 2017 requires Brussels public office-holders to declare mandates/functions and associated remuneration/benefits. It says lists for mayors, aldermen and CPAS presidents and private-remuneration bands are published on the relevant municipality's site annually, and annual reports are also published.[^parliament] Ixelles provides an official index of annual remuneration reports, public-procurement annexes, travel, and mandate lists.[^ixelles]

**Suitable claims.** A document can support `public_mandate_held(person, exact declared body/role, reporting_period)` and, if product scope permits, a distinct `declared_remuneration_band` claim. Keep “mandate”, “function”, and “derived function” as separate source vocabulary when the form distinguishes them.

**Access and reuse.** Documents are public, but the reviewed municipal pages do not state an open-data licence. Use authoritative public links and minimal excerpts. Do not republish whole tables or personal details merely because the report is public. Confirm terms separately for each publisher before bulk republication.

**Identity rule.** The declaration establishes the office-holder in its own municipal context. It does not, by name alone, establish that a similarly named company officer is the same person. Cross-source resolution needs an explicit identifier or exact name plus an independent dated role/municipality/organization corroborator. Keep ambiguous people separate.

**Semantic limit.** A declared mandate is not ownership, control, a conflict of interest, wrongdoing, or participation in a council dossier. A remuneration band is not an exact amount. A reporting-year list does not prove the mandate existed outside its stated period.

**Fail closed.** Require the responsible authority's domain, document year/version, exact person and role row, and parseable period. Reject unsigned drafts, templates, press summaries, missing table headers, OCR ambiguity, and rows whose scope cannot be tied to the person. Never derive a company/councillor “connection” until both underlying typed claims independently pass and identity resolution passes.

## 4. Procurement: award/result notices only

FPS BOSA identifies e-Procurement as Belgium's official electronic procurement platform and its Tender Bulletin as the place to search published contracts.[^bosa] For notices within TED scope, the EU Publications Office provides notice data as Linked Open Data, XML, HTML and PDF and offers a search API/direct downloads.[^ted-data] TED states that procurement notices in the OJ Supplement may generally be reused commercially or non-commercially, editorial content is CC BY 4.0, and metadata is CC0; third-party and personal-data rights can still apply.[^ted-legal]

**Suitable claim.** Only a notice explicitly classified as a result/award notice with a winning result can support `public_contract_awarded(buyer, supplier, lot, decision/conclusion date, stated value and value basis)`. Store notice ID/version, form type, lot ID, result status, buyer and winner identifiers, currency, and whether value is lot, contract, framework maximum, estimate, or another stated basis.

**Identity rule.** For Belgian buyer/supplier entities, require an organization identifier that normalizes to a valid CBE number and verify it against CBE. If the notice has only a name, publish the award as an unresolved organization mention or withhold the relationship; do not guess. Foreign identifiers require a separately defined registry verifier.

**Semantic limit.** A competition/prior-information/tender notice proves an opportunity, not an award. A result notice with “no winner”, cancellation, or unsuccessful lot proves no supplier award. Framework award value is not necessarily spend; estimated or maximum value is not payment; subcontractor and consortium members are not winners unless the result says so. An award does not prove political influence or a person's involvement.

**Fail closed.** Require an authentic signed OJ Supplement notice where TED is used: TED itself says only electronically signed notices published in the Supplement are authentic.[^ted-legal] Reject non-result forms, cancelled/no-winner lots, mismatched lot IDs, missing winner, ambiguous organization ID, unknown currency/value semantics, and corrections not applied. Always evaluate the newest linked change/correction notice. For Belgian e-Procurement notices outside TED, publication waits until BOSA's stable link/version mechanism and reuse terms are documented; the BOSA landing page alone is not an award verifier.

## Shared verifier contract

Every source adapter/verifier should output a typed result, not “official PDF = verified”:

1. Pin publisher, canonical locator, retrieval observation, bytes/hash, document/notice ID, publication time, language, parser version, and relevant excerpt/location.
2. Validate the source-specific record type before extracting the claim.
3. Resolve legal entities by registry identifier and people under the stricter person rule.
4. Preserve effective dates, reporting periods, corrections, cessations and supersession. Never substitute publication/retrieval date.
5. Emit only an allowlisted claim type with source-native role/result/value semantics.
6. Create a review case and publish nothing on ambiguity, missing fields, conflicts, layout drift, identity uncertainty, or unsupported licence/republication mode.
7. Publicly link to the authoritative origin. Private archived bytes remain evidence, not a public mirror.
8. Redact/exclude private addresses, signatures, contact details, identity numbers and family information even if present in the source.

## Open questions before implementation

- Obtain or document a first-party answer on reuse/bulk-access terms for Belgian Official Gazette legal-person annexes.
- Record the exact current CBE Open Data licence/version accepted by the operator and map only fields actually supplied by that product.
- Inventory the four MVP municipalities' mandate-report indexes, terms, document consistency and retention; only Ixelles was sampled here.
- Determine whether Belgian e-Procurement offers a documented public API, immutable notice version, and reuse licence for below-TED notices. Until then, TED is the only procurement candidate recommended for automated public award claims.
- Define supported Gazette act/role vocabulary and multilingual fixtures before enabling automatic verification.

## Primary sources

[^cbe-search]: FPS Economy, [CBE — Public Search](https://economie.fgov.be/fr/themes/entreprises/banque-carrefour-des/services-pour-tous/consultation-et-recherche-de/banque-carrefour-des) (data scope, update timing, duplicate numbers, prohibition on Public Search reuse/systematic download).
[^cbe-licence]: FPS Economy, [CBE Open Data conditions of use (PDF)](https://economie.fgov.be/sites/default/files/Files/Entreprises/BCE/Licence-BCE-Open-Data-Conditions-d-utilisation.pdf).
[^gazette-search]: FPS Justice/e-Justice, [Belgian Official Gazette — legal-person annex search](https://www.ejustice.just.fgov.be/cgi_tsv/list.pl?language=fr&page=1) (official search endpoint; searches can be scoped by enterprise/VAT number).
[^parliament]: Parliament of the Brussels-Capital Region, [Transparency for Brussels public office-holders](https://www.parlement.brussels/mandataires/) (legal framework, declarations, municipal lists and annual reports).
[^ixelles]: Commune of Ixelles, [Annual reports — remuneration and benefits](https://www.ixelles.be/site/773-Rapports-annuels-Remunerations-et-avantages?langue=fr) (official year-by-year report and mandate-list index).
[^bosa]: FPS BOSA, [e-Procurement](https://bosa.belgium.be/en/applications/e-procurement) (official platform and Tender Bulletin access).
[^ted-data]: EU Publications Office, [TED Open Data](https://docs.ted.europa.eu/ODS/latest/index.html) (LOD, XML/HTML/PDF, API and downloads).
[^ted-legal]: EU Publications Office, [TED legal notice](https://ted.europa.eu/en/legal-notice) (authenticity, reuse, CC BY 4.0/CC0, and third-party-rights limits).
