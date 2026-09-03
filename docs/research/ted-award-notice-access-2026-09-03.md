# TED award-notice access and reuse validation

_Status: decision spike for [Validate TED award-notice access and reuse](https://github.com/ricotrevisan/brussels-wtf/issues/44), not an ingestion decision. Checked 2026-09-03. Below-TED Belgian e-Procurement is out of scope._

## Result

TED is the correct source for a Belgian public-contract award claim, and the **planned link-first, metadata-only use is accepted**. The anonymous Search API and the signed-PDF direct links work today without credentials, and the legal notice permits reuse of procurement notices with attribution. The spike therefore **accepts** the planned `public_contract_awarded` projection (stable public links, minimal verified metadata, private evidentiary snapshot). It does **not** accept bulk mirroring or republishing whole notices, which remain out of scope.

Two implementation details must be pinned in the verifier ticket, but neither blocks this spike: (1) the exact awarded-value field/path, because the Search API's `result-value-lot` field is eForms "Framework Maximum Value" (BT-709), not the awarded amount; and (2) the buyer/winner identifier suffix scheme, because the eForms organisation-identifier format is still "under discussion, no restriction yet". Both are recorded below with precise fail-closed rules.

The reproducible access check is `python3 scripts/check_ted_award_notice_access.py`. On 2026-09-03 it retrieved result notice `608523-2026` (Vlaamse Milieumaatschappij → Sumaqua, winning lot `LOT-0001`), verified its digitally signed PDF, and returned a linked correction fixture (`606874-2026`, `cor-buy`).

## Checked mechanism

Two first-party mechanisms were exercised, both without credentials:

* **TED Search API** — `POST https://api.ted.europa.eu/v3/notices/search`, documented by the OpenAPI description at `https://ted.europa.eu/docs/v3` and by the developers' corner.[^ted-reusers][^ted-api] It is the "search and retrieve data published on the TED portal" API.
* **Direct notice links** — `https://ted.europa.eu/{lang}/notice/{publication-number}/{format}`, where `format` is `html`, `pdf` (non-signed), `pdfs` (signed PDF), or `xml`.[^ted-reusers] The API returns these in the notice's `links` field.

Bulk XML packages (`/packages/daily/{yyyynnnnn}` and `/packages/monthly/{yyyy-n}`) and the release calendar exist, but were not needed for a single-notice award claim and were not downloaded.[^ted-reusers]

## Authentication

* The Search API "can be accessed anonymously" and "does not require authentication, making it openly accessible to any system or user".[^ted-reusers][^ted-api-search]
* The broader TED API "allows anonymous access to all services manipulating published notices (i.e., searching for or retrieving notices already published on TED). All TED API endpoints that manipulate notices which are not yet published require the caller to be authenticated with an API key." The Search API page states "The Search API does not require a key."[^ted-api-docs]
* API keys are UUIDs without hyphens, valid 24 months, one per user, used only for the submission/validation/publication APIs.[^ted-keys]

**Project consequence:** no TED credential is required or committed for award-notice retrieval. Do not generate or store an API key for the read path.

## Rate limits and fair usage

TED states a fair-usage policy and API limits; the spike observed no rate-limit response headers, so callers must respect the documented numbers rather than wait for a 429:

* Fair usage policy: at most **600 visualizations or downloads from one IP in under 6 minutes**; at most **700 HTTP requests in the last minute**; at most **3 concurrent** daily/monthly package downloads.[^ted-reusers]
* Search API pagination mode (`PAGE_NUMBER`): at most **15,000 retrievable notices** per query, **250 notices per page**, **10,000 fields per page** (page size × requested fields). Scroll mode (`ITERATION`) removes the 15k retrieval cap but keeps the 250/page and 10k-fields/page limits, and its iteration token expires at the next OJ S release plus 24 hours.[^ted-api]

**Project consequence:** a single-notice verifier uses one search request plus one signed-PDF request, far below every limit. Bulk ingestion is not part of this slice.

## Notice identity, versions, and corrections

The notice identity fields, from the eForms SDK identifiers reference:[^eforms-identifiers]

* `BT-701` Notice Identifier — UUID v4, assigned by the Publications Office/eSender.
* `OPP-010` Notice Publication Number — `XXXXXXXXXX-YYYY` (e.g. `608523-2026`). This is the stable, human-facing publication number used in direct links.
* `OPP-011` OJEU Identifier — `XXX/YYYY` (e.g. `170/2026`).
* `BT-757` Notice Version — "01 for the initial version… any new version should have a higher version number than any previous one" (2 digits). Search field `notice-version`.
* `BT-758` Change Notice Version Identifier — "a combination of the Notice Identifier (BT-701) and the Notice Version (BT-757) of the notice being changed (eForms notices only)", format `UUID-vv`. Search field `change-notice-version-identifier`.
* `BT-140` Change Reason Code (`change-reason-code`), `BT-762` Change Reason Description (`change-reason-description`), and `BT-13716` Change Previous Notice Section Identifier (`change-previous-notice-section-identifier`) carry the correction reason and the section it changed.[^ted-field-list][^eforms-identifiers]

Observed correction behavior on 2026-09-03: result notice `606874-2026` carries `change-reason-code = cor-buy` (buyer correction) and `change-notice-version-identifier = 91609fcc-de47-4858-91f0-f0c748725685-01`, the `UUID-vv` of the notice version it changes. Legacy TED-schema corrections point `change-notice-version-identifier` at a previous publication number (e.g. `610137-2024`). Notices can also re-publish under the same publication number with a higher `notice-version` (the API returned `notice-version` values up to 22).

The Search API parameter `onlyLatestVersions=true` returns only the latest version of each notice.[^ted-api]

**Project consequence:** a verifier must resolve the **newest** correction chain before emitting a claim: query with `onlyLatestVersions=true`, then prefer the highest `notice-version` and most recent `publication-date`, and record `change-notice-version-identifier`/`change-reason-code` as correction provenance. A corrected award changes or supersedes the earlier claim; it never publishes two award edges from stale versions.

## Authenticity

TED's legal notice: "an online document is not necessarily an exact reproduction of an officially adopted text. **Only public tenders notices electronically signed published in the Supplement to the Official Journal of the European Union are authentic.**"[^ted-legal]

The `pdfs` direct link serves the **electronically signed PDF** (original language only). On 2026-09-03, `https://ted.europa.eu/nl/notice/608523-2026/pdfs` returned HTTP 200, `application/pdf`, 153,974 bytes, with a PDF signature dictionary (`/ByteRange`, `/SubFilter /ETSI.CAdES.detached`, `/Type /Sig`). The non-signed `pdf` and `html` formats are convenience renderings, not the authenticity anchor.

**Project consequence:** the authentic notice for a claim is the signed PDF (`pdfs`) or the OJ Supplement itself; the XML/HTML are convenience data. The verifier pins the signed-PDF URL, checksum, and retrieval time as evidence, and treats the notice ID/version as the source identity.

## Licensing and attribution

TED's copyright notice:[^ted-legal]

* "Unless otherwise noted, the **procurement notices published in the Supplement to the Official Journal of the European Union can be freely reused, for commercial or non-commercial purposes**", under the Commission Decision of 12 December 2011 on the reuse of Commission documents.
* Editorial content of the SIMAP sites is **CC BY 4.0** — "reuse is allowed provided appropriate credit is given and any changes made are indicated."
* SIMAP **metadata is CC0 1.0** (public domain dedication).
* Additional rights may need clearing "if specific content depicts identifiable private individuals or includes third-party works"; industrial-property items (patents, trademarks, registered designs, logos, names) are excluded, and the TED/SIMAP logos need prior consent.

**Project consequence:** a public `contract awarded to` edge may show the minimal verified fact with credit `Source: TED — tenders electronic daily (Publications Office of the European Union)`, link to the authoritative notice, and indicate that the value is a summary if changed. Metadata (notice ID/version, publication date, identifiers, dates, currency, value) is CC0. Do not use TED logos or reproduce third-party/logo content.

## Personal-data exceptions

The TED-notices privacy statement (processing record `DPR-EC-00453`) says award notices may contain:[^ted-legal]

* name of the tenderer or contractor (entity **or physical person in specific cases**);
* contact person (job title or first/last name);
* office address, professional e-mail, professional website, office phone, office fax.

TED retains these for **ten years**, then moves notices to a non-public internal archive. Data subjects have rights under Regulation (EU) 2018/1725.

**Project consequence:** the project's existing privacy policy already excludes private addresses, contact details, and identity numbers. A natural-person winner is published only when the stricter person rule in `CONTEXT.md` passes (explicit identifier, or exact name plus an independent corroborator); a name-only natural-person winner is an unresolved mention, never a verified entity. Contact-person names, e-mails, phones, and faxes in a notice are never ingested or published.

## Stable public links

Direct links are stable by publication number and documented format: `https://ted.europa.eu/{lang}/notice/{publication-number}/{format}`.[^ted-reusers] The API's `links` object returns the canonical per-notice URLs: `xml` (multilingual), `pdf` (non-signed, 24 languages), `pdfs` (signed, original languages), `html`/`htmlDirect` (reading views). The detail URL has a version slot (`https://ted.europa.eu/{lang}/notice/-/detail/{publication-number}`).

**Project consequence:** public coverage links to the per-notice direct URL `https://ted.europa.eu/{lang}/notice/{publication-number}/{format}` (or the API-provided `links`) and never to a bare search/home page as the claim anchor. The publication number is stable; a locator can change bytes, so the existing source-version/checksum model applies to private snapshots.

## Allowed storage, fields, links, refresh, and retention

* **Storage:** private evidence snapshot only (signed PDF bytes, checksum, retrieval time) under the existing source-version model; never commit or publicly mirror notice bytes.
* **Public fields:** a winning lot's buyer/winner (registry-resolved), lot identifier, award decision/conclusion date, currency, stated awarded value with its explicit basis, notice ID/version, publication date, and correction provenance — each as a neutral cited fact.
* **Excluded fields:** contact persons, professional e-mail/phone/fax, natural-person winners without the person rule, UBO fields, and any notice field outside the allowlisted claim.
* **Links:** link to the authoritative notice/version; never republish whole notices or TED logos.
* **Attribution:** `Source: TED (Publications Office of the European Union)` plus retrieval/snapshot date; mark derived text as changed under CC BY 4.0 where applicable.
* **Refresh:** on-demand re-verification per dossier; corrections applied via the newest-version rule above.
* **Retention:** TED keeps notices 10 years; the project retains private snapshots per its evidence lifecycle and drops them when the claim is superseded or the source disappears from the authoritative index. No TED clause forces a project deletion schedule for the minimal public metadata; personal-data fields are excluded before storage.

## `public_contract_awarded` claim boundary

Only a **winning lot in a result/award notice** can yield `public_contract_awarded`. The operative filter, all first-party:

* **Result/award notice:** `form-type=result` (BT-03 "Form Type") and an award/result notice type. Observed `notice-type=can-standard` (Contract Award Notice) for award results.[^ted-field-list][^eforms-bt] The fixture notice is `form-type=result`, `notice-type=can-standard`, `notice-subtype=29`.
* **Winning lot:** `winner-selection-status = selec-w` (BT-142 "Winner Chosen") on a specific `result-lot-identifier` (BT-13713, e.g. `LOT-0001`). The Search API's `winner-identifier`/`winner-name` fields are scoped to `BT-142-LotResult='selec-w'`.[^ted-field-list] The eForms code list for `winner-selection-status` is defined as "whether a tenderer was chosen to be awarded with a contract and whether the competition is open."[^eforms-codelists]
* **Never conflate:** competition/tender/prior-information notices (`form-type=competition`, `notice-type=cn-standard`/`pin-*`); no-winner or cancelled lots (`winner-selection-status` absent/not `selec-w`, or `non-award-justification` = BT-144 "Not Awarded Reason" present); estimates (`estimated-value-lot` = BT-27 "Estimated Value"); framework maxima (`framework-maximum-value-lot` = BT-271, `result-value-lot` = BT-709 "Framework Maximum Value", `result-framework-maximum-value-*`); framework re-estimated value (BT-660); tender highest/lowest (BT-711/BT-710); and payments (BT-779 "Tender Payment Value"). None of these is the awarded amount.
* **Value basis:** the awarded value must be read with its currency and an explicit basis. `result-value-notice` (`result-value-cur-notice`) is BT-161 "Notice Value"; `result-value-lot` is BT-709 "Framework Maximum Value", **not** the awarded amount. The aggregate `total-value`/`total-value-cur` (alias `TV`) mixes BT-161 + BT-118 + BT-271 + BT-27 + BT-709 + BT-660 + BT-644 and must never be used as the awarded amount.[^ted-field-list][^eforms-bt]

**Belgian buyer/winner identity:** `buyer-identifier`/`winner-identifier` are composite strings `{national_identifier}_{scheme_suffix}`. For Belgian organizations the leading segment is CBE-shaped: the fixture buyer is `0887290276_5721` (VMM) and the winner `0672875340_4ed5bfc8-…` (Sumaqua); both ten-digit prefixes pass the OpenPeppol `mod97-0208` check. CBE Open Data licensed access is validated and available: the operator registered and accepted the licence on 2026-09-02 and the authenticated download check passed, with credentials provisioned (issue [#41](https://github.com/ricotrevisan/brussels-wtf/issues/41) closed). A Belgian buyer/winner therefore resolves only by normalizing the leading ten digits and validating them with the `mod97-0208` check, then verifying against CBE Open Data (per [`cbe-open-data-access-2026-08-31.md`](cbe-open-data-access-2026-08-31.md)); the `_suffix` is a scheme/agent artifact recorded as provenance, not part of the CBE number. Foreign identifiers and name-only parties **fail closed** (see below).

## Fail-closed rules

The TED verifier publishes nothing unless all of these pass:

1. **Notice type:** `form-type=result` and an award/result notice type; otherwise no award edge.
2. **Winning lot:** `winner-selection-status=selec-w` for a matched `result-lot-identifier`; no-winner, cancelled, and unsuccessful lots emit nothing.
3. **Buyer identity:** a Belgian buyer requires a `buyer-identifier` whose leading segment normalizes to exactly ten digits passing the `mod97-0208` check and is verified against CBE Open Data. Missing, malformed, or unverifiable buyer identifiers publish nothing and open a review case.
4. **Winner identity:** a Belgian winner requires the same CBE normalization and verification. A foreign winner requires a separately defined registry verifier (not present in this slice) and fails closed until then. A name-only winner (no usable identifier) is an unresolved mention or is withheld — never a relationship.
5. **Lot/date:** the lot identifier, the winner decision date (`winner-decision-date`, BT-1451) and contract conclusion date (`contract-conclusion-date`, BT-145) are captured separately; publication/retrieval time is never substituted for either date.
6. **Currency and value basis:** currency is required; the value basis is labeled exactly (awarded amount vs estimate vs framework maximum vs highest/lowest tender vs payment). `total-value`, `result-value-lot`, and framework/estimate fields never enter the awarded amount.
7. **Newest correction:** evaluate `onlyLatestVersions=true`, then the highest `notice-version` and most recent `publication-date`; record the correction chain. A stale or superseded version produces nothing.
8. **Authenticity:** the claim links to the authentic signed notice (`pdfs` link) or the OJ Supplement; the private evidence pins bytes/checksum/retrieval time. XML/HTML alone are not the authenticity anchor.
9. **Ambiguity/drift:** missing fields, identifier-scheme ambiguity, layout/field drift, or conflicting corrections create a review case and publish nothing.

## Open blockers and owner/action

* **Awarded-value pinning (implementation, not spike-blocking).** The Search API exposes BT-161 "Notice Value" (`result-value-notice`) and BT-709 "Framework Maximum Value" (`result-value-lot`); the settled contract's awarded amount lives in the notice XML (`efac:LotTender/cac:LegalMonetaryTotal/cbc:PayableAmount` for the settled contract). **Owner/action:** the verifier ticket must pin the awarded-value field/path and value-basis label for both eForms and legacy TED-schema notices before enabling automatic claims.
* **Identifier scheme suffix.** The eForms organisation identifier (BT-501) is documented as "Discussions ongoing… No restriction yet", and this spike found no first-party code list defining the `_5721`/`_uuid` suffix.[^eforms-identifiers] **Owner/action:** the verifier ticket must record a first-party mapping for the Belgian scheme suffix (or pin to the XML `cbc:CompanyID`) and keep the strict leading-ten-digit + `mod97-0208` rule.
* **Foreign winners.** A foreign-registry verifier is not part of this slice. **Owner/action:** define it in a later spike; until then foreign winners fail closed.

## Access check

`python3 scripts/check_ted_award_notice_access.py` performs, anonymously and without saving bulk data:

1. Search `form-type=result AND winner-selection-status=selec-w` (preferring `buyer-country=BEL AND winner-country=BEL`) for the latest version of one result/award notice.
2. Print its award metadata (identifiers, lot, value + currency, dates) and version/correction fields.
3. HEAD the notice's signed-PDF `pdfs` link and, with a bounded read, confirm HTTP 200, `application/pdf`, and the `/ByteRange` + `/SubFilter` signature markers; bytes are not kept.
4. Search for one result notice that is itself a correction and print its `change-notice-version-identifier`, `change-reason-code`, and `change-reason-description`.

On 2026-09-03 it returned notice `608523-2026` (buyer `0887290276_5721` VMM, winner `0672875340_…` Sumaqua, `selec-w`, `LOT-0001`, 234,141.05 EUR, contract concluded 2026-08-12), a signed PDF at `https://ted.europa.eu/nl/notice/608523-2026/pdfs` with `/ByteRange` and `/SubFilter` markers, and correction fixture `606874-2026` (`change-reason-code=cor-buy`, `change-notice-version-identifier=91609fcc-de47-4858-91f0-f0c748725685-01`).

## Primary sources

[^ted-reusers]: Publications Office, [TED — Developers' corner for reusers](https://ted.europa.eu/en/simap/developers-corner-for-reusers) (anonymous search API, direct link formats, bulk package URLs, fair-usage limits; checked 2026-09-03).
[^ted-api]: Publications Office, [TED Search API OpenAPI description](https://ted.europa.eu/docs/v3) (endpoint `POST /v3/notices/search`, request/response fields, pagination and scroll limits, `onlyLatestVersions`, versioning; checked 2026-09-03).
[^ted-api-docs]: Publications Office, [TED API — Introduction](https://docs.ted.europa.eu/api/latest/index.html) (anonymous access for published notices; API key only for unpublished-notice endpoints).
[^ted-api-search]: Publications Office, [TED API — Search API](https://docs.ted.europa.eu/api/latest/search.html) (Search API targets reusers and "does not require authentication").
[^ted-keys]: Publications Office, [TED API — API key management](https://docs.ted.europa.eu/api/latest/api.html) (key format, 24-month validity, one key per user).
[^ted-versioning]: Publications Office, [TED API — Versioning policy](https://docs.ted.europa.eu/api/latest/versioning.html) (two active versions; breaking changes introduce a new major).
[^ted-legal]: Publications Office, [TED legal notice](https://ted.europa.eu/en/legal-notice) (authenticity, free reuse of notices, CC BY 4.0 editorial, CC0 metadata, third-party/personal-data limits, TED-notices privacy statement `DPR-EC-00453`, 10-year retention; checked 2026-09-03).
[^ted-field-list]: Publications Office, [TED Open Data — List of search fields](https://docs.ted.europa.eu/ODS/latest/reuse/field-list.html) (search-field → eForms BT mappings, including `winner-selection-status`/`winner-identifier` scoped to `BT-142-LotResult='selec-w'`, `result-value-lot` → BT-709, `result-value-notice` → BT-161, and the `TV` aggregate).
[^eforms-bt]: Publications Office, [eForms SDK — Business Terms index](https://docs.ted.europa.eu/eforms/latest/reference/business-terms/index.html) (BT-142 "Winner Chosen", BT-144 "Not Awarded Reason", BT-161 "Notice Value", BT-709/BT-271 "Framework Maximum Value", BT-118 "Notice Framework Maximum Value", BT-27 "Estimated Value", BT-145 "Contract Conclusion Date" / BT-1451 "Winner Decision Date", BT-711/BT-710 highest/lowest tender values, BT-779 "Tender Payment Value").
[^eforms-identifiers]: Publications Office, [eForms SDK — Identifiers](https://docs.ted.europa.eu/eforms/latest/schema/identifiers.html) (BT-701/OPP-010/OPP-011/BT-757/BT-758/BT-13713/BT-13716 definitions and formats; BT-501 organisation identifier "under discussion, no restriction yet").
[^eforms-codelists]: Publications Office, [eForms SDK — Code lists](https://docs.ted.europa.eu/eforms/latest/reference/code-lists/index.html) (`winner-selection-status` describes "whether a tenderer was chosen to be awarded with a contract and whether the competition is open").
