# Ixelles mandate-publication access and reuse validation

_Status: decision spike for [Validate Brussels mandate-publication access and reuse](https://github.com/RicoTrevisan/brussels-wtf/issues/43), not an ingestion decision. Checked 2026-09-03. First-slice implementation remains **blocked** for automated retrieval and republication pending written terms from the municipality; the authoritative document itself is confirmed and publicly linkable._


**Subsequent authorization:** The operator's written Ixelles authorization was
recorded in [the implementation issue](https://github.com/ricotrevisan/brussels-wtf/issues/46#issuecomment-5554481702)
for automated retrieval, private checksummed evidence, and minimal published
name/body/role/period with attribution. The permission blockers below describe
the original September 3 spike, not the current accepted scope. Excluded fiscal,
remuneration, private identity, address, and signature fields remain excluded.
See [the current acceptance record](../reviews/2026-09-13-mandate-acceptance.md).

## Result

The authoritative Brussels public-mandate source for the first municipal slice is the **Commune of Ixelles** publishing the **`Liste des mandats` 2024** (`mandats-2024.pdf`) on its official domain `www.ixelles.be` (French) / `www.elsene.be` (Dutch). The responsible authority, authoritative domain, document, reporting year, and the exact source vocabulary (`mandat`, `fonction`, `fonction dérivée`, and the six remuneration income categories) are all confirmed from first-party sources.

Automated retrieval and republication do **not** pass this spike. The municipality publishes no open-data licence, its site states personal and non-commercial use only, and `robots.txt` disallows the exact download path. Until the operator obtains written terms, the only safe policy is link-first to the authoritative document, a private evidentiary snapshot under the existing immutable source-version model, and at most a minimal necessary excerpt. **Owner/action:** Rico must request written reuse terms from the Commune of Ixelles (Ixelles DPO, `dpo@ixelles.brussels`, per the municipal privacy policy) and record the answer before any automated retrieval or republication.

## Responsible authority, publisher, and document

* **Responsible authority:** the Commune of Ixelles. The publication obligation sits on the commune: mayors, aldermen and CPAS presidents must file, by 1 October each year, a declaration for publication on each commune's website, and the commune publishes it.[^vade-mecum] The municipal site names the responsible editor as **Romain De Reusme, Bourgmestre**.[^mentions]
* **Legal framework:** the joint ordinance of 14 December 2017 of the Brussels-Capital Region and the Common Community Commission on the transparency of the remunerations and benefits of Brussels public mandate holders, fully in force since 1 December 2018; the control authority is the `Cellule Transparence des rémunérations` (Brussels Parliament services) and the sanction authority the `Commission bruxelloise de Déontologie`.[^parliament] The commune declaration uses the model of the 4 October 2018 execution decree.[^annexe2]
* **Authoritative publisher/domain:** `www.ixelles.be` (FR) and `www.elsene.be` (NL); the sitemap also advertises `ixelles.irisnet.be` / `elsene.irisnet.be` aliases.[^robots]
* **Authoritative index:** `https://www.ixelles.be/site/773-Rapports-annuels-Remunerations-et-avantages?langue=fr`, section `Liste des mandats`, listing years **2021, 2022, 2023, 2024**.[^index] The 2025 mandate list was not yet published on 2026-09-03 (only the 2025 annual report, travel list, and public-procurement annex exist).[^index] The index also lists the separate `Rapport annuel` (remuneration, presence, travel, procurement and subsidy report), which is **not** the mandate source and stays out of the first slice.
* **Authoritative document for one reporting period:** the **2024 mandate list**, `https://www.ixelles.be/site/fr/download/transparence/mandats-2024.pdf` — 132 pages, 5,206,831 bytes, `Last-Modified: Tue, 07 Apr 2026 12:17:21 GMT`, `ETag: "4f732f-64eddc3de826c"`, `Content-Type: application/pdf`, `Accept-Ranges: bytes`.[^retrieval]

## What the document actually is

`mandats-2024.pdf` is a compiled, scanned **Annexe 2** declaration bundle, not a native digital table. Its first pages reproduce the blank Annexe 2 model form (`Nom`, `Prénom`, `Numéro national`, `Adresse`, then `MANDATS`, `FONCTIONS`, `FONCTIONS DÉRIVÉES`, `RÉMUNÉRATIONS`, `AVANTAGES DE TOUTE NATURE`, plus the private-activity and income-category sections); the following pages hold each office-holder's filled declaration and the accompanying `281.10` fiscal sheets (exact amounts; the model form states the declaration is accompanied by the fiscal sheets).[^annexe2][^vade-mecum]

Each page is a scanned image with an embedded, noisy OCR text layer (a single OCR font and no native digital tables); some declarations are partly handwritten. The source therefore behaves as an **OCR-only document**: there is no native structured role row, and every parse is an OCR parse.[^retrieval]

## Version and year identity

* The reporting year is the index listing plus the filename (`mandats-2024.pdf`), and the content refers to the **2024 exercise/income year** (the `281.10` sheets say `Revenus 2024`; the private-income section covers `l'exercice fiscal qui précède la déclaration`).[^retrieval]
* The file is a **rolling compilation**: it contains declarations dated 30 September 2025 and 20 March 2026 for the 2024 exercise, and its bytes changed after initial publication (`Last-Modified` 2026-04-07, while the index page itself says `Dernière modification : 2026-06-16`).[^retrieval][^index]
* Therefore the filename year is **not** a version identity. Under `CONTEXT.md`, the version identity is the **SHA-256 of the retrieved bytes plus the retrieval observation**; `ETag`/`Last-Modified` are opaque server change signals, not content identities.[^retrieval]

## Automated retrieval terms

* No API, open-data licence, bulk endpoint, or published reuse terms exist for the mandate documents on the municipal site.[^index][^mentions][^privacy]
* The privacy policy states the site is "uniquement destiné à être utilisé à des fins personnelles et non commerciales" (personal, non-commercial use only); the pages carry the footer `Tous droits réservés`.[^privacy][^mentions]
* `robots.txt` allows `/site/` and `/` but **disallows `/site/fr/` and `/site/nl/`**.[^robots] The only working download path for the mandate list is `/site/fr/download/transparence/mandats-2024.pdf`, i.e. under a disallowed prefix; `/fr/...` and `/site/download/...` return 404.[^retrieval] A robots-compliant crawler therefore must not automatically fetch the document.
* The server does support `HEAD`, conditional `GET` (`If-None-Match` returns `304`), and byte ranges (`Accept-Ranges: bytes`, `Range` returns `206`), which allow **drift checks without re-downloading**.[^retrieval]

**Blocker.** None of this grants permission to systematically retrieve, ingest, or republish the mandate list. The safe interim is link-first, a private evidentiary snapshot obtained under operator review, and at most a minimal excerpt; bulk or recurring automated retrieval stays blocked until the operator receives written terms from the commune.[^privacy][^mentions]

## Excerpt, display, attribution, and privacy rules

* **Public link:** link to the exact document URL and to the exact index page; keep the reporting year in the citation.
* **Minimal excerpt:** quote only the minimal supporting passage (one declared `mandat` / `fonction` / `fonction dérivée` row and its section header); never reproduce whole tables or the whole document.
* **Attribution:** say `Source: Commune d'Ixelles, Liste des mandats <year>` with the retrieval date and the reporting year.
* **Prohibited fields (redact even if present in the source):** `Numéro national`, `Adresse`, signature, `281.10` fiscal sheets, exact remuneration amounts, `avantages de toute nature` amounts, and the private-income categories for this slice.[^annexe2][^retrieval]
* **Only-public-field allowlist for the first slice:** the office-holder's published name (only when the person resolves under `CONTEXT.md`), the declared `mandat` / `fonction` / `fonction dérivée` text, the reporting/exercise year and any stated period, and source metadata (publisher, canonical locator, retrieval time, SHA-256, page/location).[^retrieval]
* **Retention:** store the private snapshot as a private source version (SHA-256 + private object key) with its retrieval observation; never commit or mirror the bytes. The project becomes a controller for any personal data it copies, so it must keep only the minimal allowlisted fields and support the objection/access/correction expectations that apply to that copied personal data.[^privacy]

## Exact source vocabulary

The source distinguishes three role vocabularies and one remuneration category set:[^annexe2][^vade-mecum][^parliament]

| Source label (FR) | Meaning for the verifier | First-slice use |
|---|---|---|
| `mandat` | an enumerated mandate (elective; executive; international-instance; public-organism; a structure subject to public-procurement law; or one exercised on designation by the Government and/or the United College) | allowed, verbatim body/role text |
| `fonction` | occupation of an employment, a mission, or service work under a salaried/assimilated contract, decree, agreement or services contract within a structure subject to public-procurement law | allowed, verbatim role text |
| `fonction dérivée` | a function exercised by right because of an elective/executive mandate or a designated mandate | allowed, verbatim role text |
| remuneration income category (`catégories de revenus`; the ordinance's public-facing term is `rémunérations privées, par tranche de revenu`) | `pas de rémunération`; `de 1 à 499 euros bruts par mois`; `de 500 à 1.000`; `de 1.001 à 5.000`; `de 5.001 à 10.000`; `plus de 10.000 euros bruts par mois` (rounded to the nearest ten thousand) | **excluded** from the first slice |

The form also labels `RÉMUNÉRATIONS` and `AVANTAGES DE TOUTE NATURE` (each with a `MONTANTS` column) for remuneration from the declared mandates, and `AUTRES ACTIVITÉS EXERCÉES À TITRE PRIVÉ` for private activities. All of these are financial fields and are **excluded** from the first slice.[^annexe2]

## Approved first-slice claim

The only approved first-slice claim is:

`public_mandate_held(person, exact declared body/role, reporting_period)`

Remuneration — exact or banded, public or private — is **excluded** unless a later issue separately justifies and types a distinct claim. This spike does not authorize any remuneration claim.[^spec]

## Fail-closed rules

* **Blank template pages are not claims:** the first pages are the blank Annexe 2 model; only a filled declaration with a name and section content can carry a claim.[^retrieval]
* **Unsigned drafts:** reject a declaration that is filled but unsigned; the Annexe 2 form ends with a signature and a dated attestation, so an unsigned copy is a draft, not an accepted declaration.[^annexe2][^retrieval]
* **Press summaries and secondary write-ups are never the source:** only the official PDF under the authoritative domain counts.
* **Missing headers:** reject when the `MANDATS` / `FONCTIONS` / `FONCTIONS DÉRIVÉES` section headers, a person name, or the reporting year cannot be tied to the row.
* **OCR ambiguity:** the source is OCR-only and partly handwritten; any uncertain row creates a review case and publishes nothing.[^retrieval]
* **Ambiguous identity:** a name alone never resolves a person; require the `CONTEXT.md` exact-name-plus-corroborating-fact rule (municipality, dated mandate, organization, or role).
* **Out-of-period inference:** a 2024 list proves the mandate only for the declared 2024 period; it must never be presented as current or extended to other years.
* **Drift and corrections:** a changed `ETag`/`Last-Modified` or new bytes at the locator create a new source version; re-verify before emitting or updating a claim.

## Primary sources

[^parliament]: Parliament of the Brussels-Capital Region, [Transparency for Brussels public office-holders](https://www.parlement.brussels/mandataires/) (ordinance of 14 December 2017, in force 1 December 2018; `mandat`/`fonction`/`fonction dérivée` vocabulary; commune publication of mayors/aldermen/CPAS presidents by 1 October with private remuneration by income band; control and sanction authorities; checked 2026-09-03).
[^vade-mecum]: Brussels Parliament `Cellule Transparence des rémunérations`, [Vade-mecum Transparence 2026-02-04 (FR)](https://www.parlement.brussels/wp-content/uploads/2022/02/Vade-mecum-Transparence-2026-02-04_FR.pdf) (definitions of `fonction` and `fonction dérivée`; article 3 enumeration; filing deadlines and recipients; the six income categories; IRISbox declaration workflow; checked 2026-09-03).
[^annexe2]: Brussels Parliament `Cellule Transparence des rémunérations`, [Annexe 2 — declaration model for publication on each commune's website](https://www.parlement.brussels/wp-content/uploads/2020/12/Vade-mecum-Transparence-2020-11-27-FR-Annexe-2.pdf) (exact `MANDATS` / `FONCTIONS` / `FONCTIONS DÉRIVÉES` / `RÉMUNÉRATIONS` / `AVANTAGES DE TOUTE NATURE` labels, `Numéro national`/`Adresse` fields, and the six income categories; checked 2026-09-03).
[^index]: Commune of Ixelles, [Rapports annuels — Rémunérations et avantages](https://www.ixelles.be/site/773-Rapports-annuels-Remunerations-et-avantages?langue=fr) (official index with `Liste des mandats` 2021-2024; `Dernière modification : 2026-06-16 08:04:25`; checked 2026-09-03).
[^mentions]: Commune of Ixelles, [Mentions légales](https://www.ixelles.be/site/581-Mentions-legales) (responsible editor Romain De Reusme, Bourgmestre; footer `Tous droits réservés`; checked 2026-09-03).
[^privacy]: Commune of Ixelles, [Politique de confidentialité](https://www.ixelles.be/site/921-Politique-de-confidentialite) (personal and non-commercial use only; Ixelles DPO, `dpo@ixelles.brussels`; controller is the Commune d'Ixelles; checked 2026-09-03).
[^robots]: Commune of Ixelles, [robots.txt](https://www.ixelles.be/robots.txt) (`Disallow: /site/fr/` and `/site/nl/`, `Allow: /site/` and `/`; sitemap aliases; checked 2026-09-03).
[^retrieval]: Direct retrieval on 2026-09-03 of `https://www.ixelles.be/site/fr/download/transparence/mandats-2024.pdf` (status, type, size and headers quoted above) and inspection of its embedded text layer; no source bytes were committed.
[^observation]: [Ixelles mandate access observation — 2026-09-03](evidence/ixelles-mandate-access-observation-2026-09-03.md) (byte-free record of the retrieved URL, ETag, Last-Modified, Content-Length, SHA-256, and non-personal header counts).
[^spec]: [Public Evidence Graph and Follow Product Specification](../specs/public-evidence-graph-and-follow.md), mandate verification and remuneration-band separation; [public evidence sources research](../research/public-evidence-sources.md), Brussels mandate section.

## Reproducible access check

`python3 scripts/check_ixelles_mandate_access.py` resolves the index page and the exact 2024 document's version signals via `HEAD` **without downloading the document**; the document body is fetched into memory (and discarded) only under the explicit `--fetch-document` flag, because the download path is robots-disallowed. With `--fetch-document` it also records the SHA-256 and a parseable role row. No source bytes or personal data are written or committed. The observed version signals, digest, and header counts are recorded in [`docs/research/evidence/ixelles-mandate-access-observation-2026-09-03.md`](evidence/ixelles-mandate-access-observation-2026-09-03.md).[^observation] Run `python3 scripts/check_ixelles_mandate_access.py --self-test` for the offline helper tests.
