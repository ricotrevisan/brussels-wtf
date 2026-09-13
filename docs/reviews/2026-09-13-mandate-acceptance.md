# Ixelles declaration acceptance

Work: [Publish one Brussels public mandate end to end](https://github.com/ricotrevisan/brussels-wtf/issues/46).

## Gap and change

The earlier declaration processor already supported inspected OCR, immutable
source versions, dated multilingual facts, and corrections. Its identity gate,
however, required an appointment sentence containing an explicit bracketed
identifier. The synthetic fixture satisfied that shape; the real Ixelles
minutes do not. That fixture did not establish a production declarant identity.

The v3 declaration verifier adds one inspected independent identity source:
physical page 1 of [Ixelles' 11 June 2026 minutes](https://www.ixelles.be/uploads/conseil/pv/267.pdf#page=1)
names Gautier Calomne in the aldermen's attendance group. The complete name,
municipality, and sourced role corroborate the declarant. This evidence creates
no appointment fact and does not extend the declaration's December 2024 period.
Existing ambiguous or uncorroborated identities are not merged or overwritten.

The identity gate checks the pinned source checksum, byte length, source role,
commune, exact origin, discovered meeting/date/index, and successful retrieval
observation. Actual archived bytes are checked before identity creation and again
before verification. The declaration's private claim artifact retains the
identity evidence; public output excludes private corroborators. Changing the
independent source context withdraws dependent public coverage.

Earlier v2 facts retain their evidence and audit history. The v3 processor shares
the declaration semantic lock and uniqueness constraint with v2, so upgrading a
verifier cannot create two current declarations. Rollback hides v3 facts without
erasing them.

Acquisition now uses the index version attached to the exact retrieval
observation, verifies archived bytes and the final origin, and parses actual HTML
anchors. A reverted index, a comment/script containing an apparent link, or an
unexpected redirect cannot borrow another snapshot's declaration link.

Readers can find verified declared mandates from the homepage, within the
selected communes. Each entry includes the declared period and links to the
exact person-page fact. The existing localized role and dated-history display
now links directly to the cited PDF page. This is a list of accepted declarations,
not a complete/current directory of councillors or a claim of dossier involvement.

## Retained source contracts

Re-fetched on 2026-09-13; both match the previously inspected bytes:

| Source | SHA-256 | Bytes | Evidence |
| --- | --- | ---: | --- |
| [Ixelles 2024 mandate compilation](https://www.ixelles.be/site/fr/download/transparence/mandats-2024.pdf) | `c5b717d6243bd8ad3957f486ca9408a153c636927314642d03ec50e4505fbca2` | 5,206,831 | Declaration page 14; inspected attestation page 17 |
| [Ixelles minutes 267](https://www.ixelles.be/uploads/conseil/pv/267.pdf) | `4ac4ed359acbc2d6f245226657f8a43e533281d533b3f16e1a3701ec97db87e5` | 1,669,707 | Independent identity context, page 1; meeting 11 June 2026 |

The declaration remains `Premier Echevin et Officier de l'Etat Civil`,
1–31 December 2024. This is not a statement about a present-day role.
The prior written Ixelles authorization recorded in the issue remains applicable;
no new correspondence or permission was requested.

Raw PDFs, full OCR text, and signature/fiscal material remain outside Git and
public responses. The existing minimal source fixture is unchanged.

## Reproduce acceptance

The normal test suite includes invalid/ambiguous identity, header/scope/period
failures, correction ordering, idempotency, public privacy and source-withdrawal
checks. `mix test.browser` additionally exercises homepage discovery and the exact
fact/page link in FR/NL/EN at 1280px and 390px using isolated synthetic input.

The external acceptance requires privately retained `minutes-267.pdf`,
`mandats-2024.pdf`, `mandats-ocr.pdf`, and `mandats-ocr.txt` in
`MANDATE_EVIDENCE_DIR`. Generate the latter two using the documented bounded
[OCR contract](../../test/support/fixtures/ixelles/mandates/README.md).

```sh
MIX_ENV=test MIX_TEST_PARTITION=mandate_acceptance \
  MANDATE_EVIDENCE_DIR=/private/path/to/evidence \
  MANDATE_BROWSER=1 PLAYWRIGHT_CHROMIUM_EXECUTABLE=/usr/bin/chromium \
  mix test --include external --include browser \
  test/brussels_wtf/identity_mandate_declaration_test.exs \
  test/brussels_wtf/mandate_declaration_contract_test.exs
```

This uses the actual pinned PDFs and the captured real OCR output through the
controlled HTTP/PDF boundary, with the real application acquisition, archive,
identity, verifier, database, and browser layers. It does not pretend that the
controlled adapters performed network access or OCR during ExUnit. An independent
container run performed OCR on pages 14 and 17 with `fra+nld`, force-OCR, page
segmentation mode 6, one CPU, 1 GiB RAM, and no network. No real-source test bytes
or identity contracts are injected into production configuration.

The first combined run passed 27 tests, including the real-document and browser
journeys. Public-source dates shown during ExUnit are controlled test observations,
not production publication evidence.

## Release boundary

No production mutation or deployment is established by these tests. Before live
acceptance, deploy the reviewed migration/code, inspect the existing Ixelles 267
source and locator lineage, then run the existing bounded declaration acquisition
with an authenticated poll-run identity. Missing independent evidence opens a
review case. It must not be replaced with a fabricated municipal identifier.
The normal isolated OCR queue and trusted verifier produce the public fact.

Verify the actual person URL, homepage discovery, all locale variants, private
archive access, and the absence of duplicate facts on the deployed release before
closing the ticket. Existing operational deployment/queue holds still apply.
