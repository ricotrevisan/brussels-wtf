# CBE Open Data access and reuse validation

_Status: decision spike for [Validate CBE Open Data access and reuse for the identity spine](https://github.com/RicoTrevisan/brussels-wtf/issues/41), not an ingestion decision. Checked 2026-08-31. Production access is **blocked** pending operator registration and licence acceptance._

## Result

CBE Open Data is the correct product for a Belgian legal-entity identity spine, but this spike did not download it. The official portal requires registration and acceptance of the CBE Open Data licence. No project account or accepted-licence record was available, and an agent must not accept legal terms for the operator. **Owner/action:** Rico must register the intended reuse purpose at the official portal, review and accept the then-current terms, and record the accepted PDF (including its hash/date because the current PDF has no printed version) in the private compliance record. He must then provide credentials through the deployment secret store and run an authenticated, non-production download check. Until that happens, implementation and publication from CBE Open Data remain fail-closed.

The public preflight is reproducible with `python3 scripts/check_cbe_open_data_access.py`. It checks the official product page, licence, catalogue, cookbook, and registration portal without credentials or data download. On 2026-08-31 all five endpoints responded. This proves only that the registration materials are reachable, **not** that the licensed product can be obtained.

## Product and terms checked

* Product: **CBE Open Data**, CSV full and update ZIP files. The official cookbook identifies its schema as **R018.00**.[^cookbook]
* Licence: official French `Licence OPEN DATA : conditions d’utilisation` PDF retrieved on 2026-08-31.[^licence] It has no visible version number or effective date. That is the precise unresolved licence-version blocker. The terms can change with notice and silence after 15 days counts as acceptance (article 9.1), so production must retain the privately accepted artifact and monitor notices.
* Access: anyone may register and accept the terms. Files are then available manually from the portal or, after a request to the address published on the product page, by SFTP.[^product] Credentials must stay in the secret store.
* Delivery: free CSV files; a full snapshot and changes file are produced daily and portal copies remain available for 31 days. Technical problems may alter the schedule.[^product][^cookbook]

## Allowed scope for this product

The dated catalogue, not Public Search, limits reusable fields.[^catalogue] For this product the planned identity projection may ingest only:

* enterprise number, registered-entity type, denomination type/language/name;
* start date, legal form, legal situation, and status;
* activities (category, NACE-BEL code/version, principal/secondary/auxiliary type);
* only if later needed and privacy-approved: the catalogue's legal-person registered-office fields;
* establishment/branch identifiers and fields only as separately typed establishment/branch records, never as enterprise identity keys.

The product contains active entities and active establishments only and no history. The cookbook's `enterprise.csv`, `denomination.csv`, and relevant `code.csv` are sufficient for the initial spine. Do not ingest `contact.csv` or address files for this slice. Do not publish private addresses, contacts, or attributes of registered natural-person entities.

**Legal functions are not listed in the Open Data catalogue or R018.00 cookbook.** Therefore this product cannot supply a `legal_function` claim, and any code seen elsewhere is unmapped/unsupported and must create a review case. A separately licensed/source-verified product would need a new validation spike.

## Reuse, display, storage, and lifecycle policy

The licence permits sharing, modification, and reuse of only the public data in the Open Data catalogue (article 1). It requires the declared registration purpose to remain the purpose of reuse (2.3), forbids distortion (2.7), and requires both the source and information update date (2.8). Every public display must therefore say `Source: CBE Open Data (FPS Economy)` and show the snapshot/update date. It must not imply an FPS guarantee or endorsement.

The licensee is the controller for personal data, must support objection, access, and correction, and must not use personal data for direct marketing (2.1–2.2). Rights and duties cannot be transferred or subcontracted (article 11); deployment/vendor arrangements need operator legal review before licensed files are disclosed. The licence has indefinite duration, but FPS may terminate it and automatically ends it after one year without downloads (articles 8 and 10).

No licence clause grants indefinite retention of stale facts or requires deletion on a fixed schedule. The safe planned policy is:

1. keep licensed bulk ZIP/CSV private with access controls; never commit or publicly mirror it;
2. refresh daily, apply update delete/insert semantics, and attach `SnapshotDate`, extract number, schema version, and retrieval time;
3. publish only the minimal current legal-entity fields above with attribution and update date;
4. remove a record from the current public projection when an update/full snapshot removes it; do not infer a cessation date because the product has no history;
5. process data-subject objection/access/rectification and licence termination notices as compliance review cases; suspend affected publication while unresolved;
6. on termination or purpose change, stop reuse and have the operator/legal owner decide and document deletion of licensed raw and derived data. The licence does not state the post-termination deletion period, so production may not invent one.

## Identity and fail-closed rules

**Source facts:** the CBE cookbook defines `EntityNumber` in the dotted formats `9999.999.999` or `9.999.999.999` and uses it to relate the Open Data files.[^cookbook] OpenPeppol's official Belgian enterprise-number validation rule requires exactly ten digits and its Belgian `mod97-0208` check.[^peppol-rule]

**Project policy:** a Belgian legal entity resolves automatically only from that enterprise number after removing the cookbook's presentation dots and validating the resulting ten digits with the OpenPeppol rule. Preserve the source value and evidence. Do not silently repair a number or infer one. Names, phonetic names, addresses, postcodes, establishments, and model similarity are search hints only and never identity keys. This is deliberately stricter than accepting a value merely because it occupies the CBE field.

* Missing, malformed, or invalid enterprise number: publish no entity/link; create a review case.
* Duplicate/redirect: Public Search says a closed duplicate number redirects to the retained number.[^public-search] Never silently merge. Preserve both identifiers and the redirect evidence, then require a source-supported alias/redirect record or review.
* Establishment number or branch ID: never promote to an enterprise number. Resolve only through the explicit Open Data relation.
* Unknown code or schema/catalogue version: publish no affected field and create a review case.
* Natural-person registered entity or a natural-person name: do not resolve a project person from name/address. Exclude it from this spine. A person requires the separate `CONTEXT.md` corroboration rule and privacy review.
* Open Data is current-state evidence. Do not manufacture historical dates, ownership, management, or cessation.

## Public Search boundary

Public Search is for targeted, entity-by-entity human verification links only. Its official page expressly forbids reuse and systematic continuous download.[^public-search] It must never be scraped, bulk-ingested, cached as a dataset, or republished. A Public Search result or redirect is not a licence to ingest its fields. Automated reuse must use the separately registered CBE Open Data product.

## Primary sources

[^product]: FPS Economy, [CBE Open Data product and access page](https://economie.fgov.be/fr/themes/entreprises/banque-carrefour-des/services-pour-tous/reutilisation-de-donnees/banque-carrefour-des-0) (daily full/update files, 31-day availability, registration, licence acceptance, portal/SFTP access; page updated 26 November 2025).
[^licence]: FPS Economy, [CBE Open Data conditions of use](https://economie.fgov.be/sites/default/files/Files/Entreprises/BCE/Licence-BCE-Open-Data-Conditions-d-utilisation.pdf) (rights, purpose, attribution, personal data, delivery, changes, termination, non-transferability; retrieved 2026-08-31; no printed version/date).
[^catalogue]: FPS Economy, [Catalogue of reusable CBE Open Data fields](https://economie.fgov.be/sites/default/files/Files/Entreprises/BCE/Catalogue-des-donnees-reutilisables-BCE-opendata.pdf) (field allowlist and active-data scope; retrieved 2026-08-31).
[^cookbook]: FPS Economy, [CBE Open Data cookbook R018.00](https://economie.fgov.be/sites/default/files/Files/Entreprises/BCE/Cookbook-BCE-Open-Data.pdf) (access, daily/31-day lifecycle, no history, file/update semantics, schema; retrieved 2026-08-31).
[^public-search]: FPS Economy, [CBE Public Search](https://economie.fgov.be/fr/themes/entreprises/banque-carrefour-des/services-pour-tous/consultation-et-recherche-de/banque-carrefour-des) (human query scope, next-day data, duplicate redirects, and explicit reuse/systematic-download prohibition; page updated 7 November 2025).
[^peppol-rule]: OpenPeppol, [PEPPOL-COMMON-R043: Belgian enterprise number format](https://docs.peppol.eu/poacc/billing/3.0/rules/ubl-peppol/PEPPOL-COMMON-R043/) (primary validation specification requiring ten digits and the `mod97-0208` check; accessed 2026-08-31).
