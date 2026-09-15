# Ixelles TED award: identifier and signature contract

_Checked 2026-09-16 for [#47](https://github.com/ricotrevisan/brussels-wtf/issues/47). Bounded research against the privately retained January/March 2026 notices; no publication decision, source upload, correspondence or new access permission. Supplements [the accepted TED access spike](ted-award-notice-access-2026-09-03.md)._

## Result

An exact inspected mapping of this notice's two organization identifiers to the independently checked CBE records is reviewable. A generic Belgian underscore-suffix scheme remains **unproven**. Reading XML does not remove that ambiguity: its `cbc:CompanyID` contains the same suffix and has no scheme attribute.

The March PDF contains more than a signature marker: whole-file signature math and an embedded timestamp's signature/imprint checks pass. Its signer certificate expired after that timestamp. Nevertheless, local strict archival validation returns `INDETERMINATE/NO_POE`. Do not turn an optimistic lower-level `VALID` summary into full historical acceptance. This limitation is specific to the selected chain; a newer local award with a currently valid signer certificate may avoid it without weakening evidence rules.

## Inspected source versions

These are local SHA-256 calculations over the previously acquired official files; complete documents remain private. Official signed sources: [22171-2026](https://ted.europa.eu/fr/notice/22171-2026/pdfs) and [181194-2026](https://ted.europa.eu/fr/notice/181194-2026/pdfs).

| Notice | Format | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| 22171-2026 | XML | 24,357 | `047e0bff028a365858f3aab344f0eb7cbd7db58adb7d4727fbb8411dc7f425f0` |
| 22171-2026 | signed PDF | 169,613 | `0548f821ce1bfcc83806b2532453a64515762dde50ea24b127951c72ff0710a0` |
| 181194-2026 | XML | 27,498 | `a30f4840eb60829fd0223ffc2d09201300bf63c0ef3920a55677b9388262d829` |
| 181194-2026 | signed PDF | 188,163 | `90c19ef15b29688326b9d0b0d8c7ac7e8445f332c888d0c519da2d8d392cebc6` |

The March notice changes the January notice; the separate extraction contract must retain the explicit predecessor UUID/version and lot-level result. This note does not establish that every later correction has been ruled out.

## Organization identity

TED's current BT-501 reference still leaves the organization identifier format unrestricted and assigned by the contracting authority. `ORG-xxxx` is a different, notice-local technical reference. Neither rule specifies the Belgian underscore suffix. Bounded searches of TED and BOSA material found no first-party suffix definition. BOSA's older organization-management manual labels a business-number field as KBO, but predates eForms and cannot define today's export format. [TED identifier reference](https://docs.ted.europa.eu/eforms/latest/schema/identifiers.html), [TED FAQ](https://docs.ted.europa.eu/eforms-common/FAQ/index.html), [BOSA manual](https://bosa.belgium.be/sites/default/files/documents/Handleiding_gebruikersbeheer_onderneming_nl_20200331.pdf).

The inspected March XML and signed PDF bind these exact records:

| Technical reference | Complete CompanyID, unchanged | Notice name | Proposed exact CBE mapping | Official PDF location |
| --- | --- | --- | --- | --- |
| ORG-0001 | `0207401341_7321` | Commune d'Ixelles - Gemeente Elsene | `0207401341` | section 8.1, physical page 5 |
| ORG-0005 | `0844814966_8106565a-eb99-4a8d-a4df-2263a7e4511c` | CHUBB SOMATI SYSTEMS | `0844814966` | section 8.1, physical page 6 |

Both XML company addresses identify country `BEL`; neither CompanyID has a scheme attribute. These observations come from the pinned XML and corresponding signed-PDF organization rows, not search-result normalization. [March notice](https://ted.europa.eu/fr/notice/181194-2026/pdfs).

The independently produced private CBE adapter receipt was read during this research. It resolves `0207401341` to active legal person `Commune d'Ixelles` and `0844814966` to active legal person `CHUBB SOMATI SYSTEMS`. Both use release `cbe-open-data:470:2026-09-01:1.0.0`, digest `afbc36d006b123d0426fe6f106afb1023ae1fe017cd4b514d2167f3551f41b49`. This is an inspected receipt of the licensed source check; this research did not download the release again. A separate official federal agreement also explicitly associates Ixelles with enterprise number 0207.401.341. [FPS Mobility agreement, page 1](https://mobilit.belgium.be/sites/default/files/documents/publications/2022/Protocollen%20GAS/integratiediensten/Parkeerbeheer/Parkeerbeheer%20akkoorden/220711_ROAD_FR_ixelles_-_elsene.pdf).

### Proposed bounded mapping contract

Use a two-entry, source-version-specific mapping, keyed by exact notice/version, XML/PDF hashes, organization reference, complete raw CompanyID, country and exact inspected name. Require the actual licensed CBE record and release provenance on every verification. Retain the unmodified raw identifier and mapping-contract version. Record that the mapping was inspected across these sources; never label it a BOSA-defined suffix scheme.

Do not implement `split("_")[0]` as a general identity resolver. A different suffix, number, name, country, organization reference, source hash or correction requires another inspected contract. Mod97 checks only numeric syntax. Names, addresses and numeric shape alone never produce an entity or award relationship. The older spike's generic suffix-normalization language must not be treated as proof of a national scheme.

This is an implementation proposal supported by explicit notice fields plus independently verified registry identities. It cannot resolve the separate signed-source trust question, and it does not authorize a production fact.

## Signature evidence

TED documents `pdfs` as its signed-PDF download and distinguishes electronically signed notices from convenience online renderings. Its legal notice also records preservation of daily Supplement issues in the Publications Office's long-term repository since 2022. These are reasons to retain the official origin and bytes; they are not a local certificate-validation receipt. [TED direct formats](https://ted.europa.eu/en/simap/developers-corner-for-reusers), [TED legal notice](https://ted.europa.eu/en/legal-notice).

Local inspection of the March PDF found:

- Poppler `pdfsig` 25.03.0: one `ETSI.CAdES.detached` signature, valid cryptographic signature, total-document coverage, expired certificate. Byte ranges are `[0,168520]` and `[187466,188163]`.
- Signer `ARHS SPIKESEED SA`; issuer `CAEDICOM04`. Certificate SHA-256 `93aa272579f09a3a7bbaff3a2053cb5abaa33500d84fdc56fc101ec205b3317b`, valid from `2024-06-20T13:40:57Z` through `2026-06-20T13:40:56Z`.
- The CMS unsigned attributes contain a signature timestamp token. Its `genTime` is **2026-03-15T23:08:36Z**. The `pdfsig` display `Mar 16 00:08:36` is local time, not UTC. The timestamp's SHA-512 imprint equals the hash of the main CMS signature value.
- Token signature math succeeds with OpenSSL. `cms -verify -noverify` was used only to isolate cryptographic integrity: that option explicitly skips signer-certificate trust verification. It is not an authenticity gate. [OpenSSL option documentation](https://docs.openssl.org/3.5/man1/openssl-cms/).
- Timestamp signer `TSA EDICOM`, issuer `CAEDICOM04`; certificate SHA-256 `367995c1035a4b83dec975e25c03d2414271c01ad3caf37234519fc8443e982c`, validity `2023-09-18T13:53:50Z`–`2028-09-16T13:53:49Z`.
- No PDF `/DSS`, document timestamp or embedded CMS revocation-data attribute was found. A signature timestamp is not itself a complete archive of certificate/revocation evidence.

The official Spanish trusted list publishes the exact TSA serial `24217874336344652862153966656655337354209`, with service status granted from 2024-06-10. It also publishes CAEDICOM04, fingerprint `b211c48c2bd45066dddc3c62658b135d85fe1305896fe32faa2be70ba4aa0773`, with granted service history covering the relevant dates. The EC DSS viewer reports the list validation as `TOTAL_PASSED`. The local script selects that CA certificate from the official HTTPS XML; it does not independently validate the TSL XML signature or infer qualified-signature status. [Official Spanish TSL](https://tsl.digital.gob.es/TSL.xml), [EC trusted-list readout](https://ec.europa.eu/digital-building-blocks/DSS/webapp-demo/tl-info/tl/TL-71AD2569349372DBD8554C9E72A58E24A9DA7FF0D0BC5F2CA3086DF3972EFD6C).

## Historical validation and its limit

Use trusted time evidence, chain validation and appropriate revocation evidence to validate a signature after certificate expiry. A claimed signing time is insufficient. DSS distinguishes validation with time/long-term material from archival validation and exposes detailed failure results. [European Commission DSS documentation, sections 3.3.8 and 7](https://ec.europa.eu/digital-building-blocks/DSS/webapp-demo/doc/dss-documentation.html), [ETSI EN 319 102-1 v1.4.1, sections 5.5–5.6](https://www.etsi.org/deliver/etsi_en/319100_319199/31910201/01.04.01_60/en_31910201v010401p.pdf).

An isolated pyHanko 0.37.0 run used the above CA, `REQUIRE_REVINFO`, default freshness and `retroactive_revinfo=False`, without invented historical proofs or nonrevocation assertions. March results:

| Check | Result | Meaning |
| --- | --- | --- |
| Full-file digest/signature | intact, valid | Bytes match the signature |
| Signature timestamp | intact, trusted | Bound timestamp verifies against the selected CA |
| `ades_with_time_validation` | `AdESPassed.OK` | Lower-level result; insufficient by itself for this expired-certificate case |
| `ades_lta_validation` | `AdESIndeterminate.NO_POE` | Past validation cannot establish signer-certificate existence at its control time |

The January predecessor independently returned the same archival `NO_POE` result, with an intact/trusted timestamp at `2026-01-12T23:23:22Z`. Both results are retained in the private receipt.

The lower-level result must not override the archival result. The installed first-party implementation explicitly notes that its time-validation path cannot process expiry without timestamped revocation information; its archival result carries a failure even when the compatibility status pretty-printer says `VALID`. Consume the returned AdES indication and failure, not a text substring. [pyHanko source](https://github.com/MatthiasValvekens/pyHanko/blob/v0.37.0/pkgs/pyhanko/src/pyhanko/sign/validation/ades.py), [first-party validation guide](https://github.com/MatthiasValvekens/pyHanko/blob/master/docs/lib-guide/validation.rst).

One direct public OCSP query returned `SUCCESSFUL/GOOD` for the expired signer certificate, with `thisUpdate=2026-09-15T23:18:44Z`, `nextUpdate=2026-09-16T23:18:43Z`, and no response/single-response extensions. This was decoded diagnostic output, not a separately accepted historical OCSP validation. A current response is not automatically a March revocation receipt. No retroactive-revocation bypass was enabled.

## Reproduction and next action

Private evidence directory: `/home/rico/.local/share/brussels-wtf/task-evidence/real-evidence-connections/`.

```sh
uv run --no-project --with pyhanko==0.37.0 python \
  /home/rico/.local/share/brussels-wtf/task-evidence/real-evidence-connections/check_ted_signature.py
```

The script checks both chain PDFs, fetches public trust/revocation information, and writes `ted-signature-validation-receipt.json` and `ted-signature-spanish-tsl.xml` privately. It never uploads a document or changes its bytes. Each validation call has a 90-second deadline. CBE readback is in `real-evidence-cbe-check.log` in the same private directory.

Smallest next action: select a newer, locally relevant award/correction chain whose signed sources can pass the existing trust policy with currently valid certificates, then apply exact organization mappings and the parent task's lot/value/correction contract. Alternatively, obtain and validate sufficient historical certificate/revocation preservation evidence for this chain through an existing official mechanism; do not replace missing evidence with a hard-coded acceptance flag. A further independent local DSS check can characterize the pyHanko limit, but no such result is claimed here. Identifier mapping, source authenticity, extraction tests, deployed code and actual public facts remain distinct acceptance steps.

## Follow-up: current City of Brussels award 612281-2026

This newer [official signed notice](https://ted.europa.eu/fr/notice/612281-2026/pdfs) removes the expired-signer-certificate problem. It introduces a separate certificate-purpose/profile question; the checks below distinguish that question from source acquisition, signature math and legal nonrepudiation.

### Source and exact public fields

Local hashes: signed PDF 159,243 bytes, SHA-256 `d1c814761e6fc5fec223c19dd92a7f8b83ebc2120d65e6ed93314a1982ea1edd`; XML 20,089 bytes, SHA-256 `2812dfdd6b15b3af3a0d8730d499e36bb713a1cedb8eaf57bb569e72e957eb13`. XML notice UUID `c618fd8a-1b31-4fbd-bb9c-2c385c6b5c93`, version `01`.

The actual PDF independently confirms:

| Location | Inspected field |
| --- | --- |
| Physical page 2, section 5.1.15 | No framework agreement; no dynamic purchasing system |
| Physical page 3, section 6.1.2 | ROAD SWEEPER RENTING; tender and contract identifier `ROAD SWEEPER RENTING-LOT-0001`; lot `LOT-0001` |
| Same section | Tender value **4,129,220.00 EUR**; contract concluded **2026-08-31** |
| Physical page 3, section 8.1 | Buyer `Bruxelles`, raw registration ID `0207373429_4620` |
| Physical page 4, section 8.1, ORG-0004 | Winner `ROAD SWEEPER RENTING`, raw registration ID `0434042237_33f448a8-4ee6-4d82-858e-726222f370f8` |

These are signed-source observations, not a payment amount or a person's involvement. Keep the tender-value basis even though the notice aggregate happens to equal it. The parent task separately verifies the XML lot graph and correction search. The proposed exact registry mappings are `0207373429_4620 → 0207373429` and `0434042237_33f448a8-4ee6-4d82-858e-726222f370f8 → 0434042237`, conditional on actual CBE readback; this research does not infer those identities solely from the names or numeric prefixes.

### Actual cryptographic checks

Signer certificate: `ARHS Developments SA`, issuer `CAEDICOM04`, fingerprint `b2b6a4ae508c263f7d323654a9abdeb25b3bdb78d65e8588ad4b7d6a768e328a`; validity `2026-06-19T14:37:05Z`–`2029-06-18T14:37:04Z`. The signature timestamp is `2026-09-03T22:03:24Z`. There is one whole-file signature and no `/DSS` or archival document timestamp.

- Whole-file signature math passes; timestamp integrity and trust pass against the same pinned CAEDICOM04. The AdES validation collected two OCSP responses, for signer and timestamp chains.
- pyHanko's default PDF policy returns `CHAIN_CONSTRAINTS_FAILURE` because it requires `non_repudiation`. That is a **library default**, not a requirement of #47. Its first-party documentation explicitly supports selecting `digital_signature` for applications with different requirements. [pyHanko key-usage configuration](https://docs.pyhanko.eu/en/latest/cli-guide/config.html#key-usage-settings).
- The actual signer has `digitalSignature=true`, `contentCommitment=false`, and EKU **clientAuth only**. Certificate policy OID is `1.3.6.1.4.1.30051.2.3.2.12` (non-qualified signing).
- An explicit diagnostic requiring `digital_signature` and the actually present `client_auth`, with mandatory revocation checks, default freshness and no historical exceptions, returns `INTACT:TRUSTED`, trusted timestamp, and `ENTIRE_FILE`. This proves the selected chain/current revocation and signature checks; it does **not** establish that clientAuth authorizes generic document signing.
- Archival AdES validation still yields `NO_POE`, including with a currently valid signer. A proof of long-term archival preservation is stronger than current source-authenticity acceptance. Do not turn absence of archival material into a new blanket TED requirement.

### First-party purpose evidence and remaining mismatch

The issuer's current **Certificate Policy for Non-Qualified Signature**, version 2.1 dated 2026-03-11, identifies this exact OID and permits digital signatures. Physical page 11 describes allowed usage; its certificate-profile annex on physical page 27 specifies `DigitalSignature`, `KeyEncipherment`, `DataEncipherment` and says the Extended Key Usage extension is absent. The actual certificate's clientAuth-only EKU therefore differs from the documented profile. The policy also directs relying parties to obey both KU and EKU. [Issuer policy](https://acedicom.edicomgroup.com/eu/CAEDICOM%20-%20Unqualified%20Signature%20Certificate%20Policy.pdf), [issuer policy index](https://acedicom.edicomgroup.com/eu/caedicom_en.xml).

The inspected issuer policy is 686,599 bytes, SHA-256 `54ef8f41dfe4d780b40c8338c41397af9ee3502a7d425aee84e41ecf8d2662fc`. RFC 5280 distinguishes digital-signature usage from content commitment and restricts an EKU-bearing certificate to a consistent listed purpose. `clientAuth` identifies TLS client authentication. A general-purpose X.509 document-signing claim should not silently ignore that field. [RFC 5280, sections 4.2.1.3 and 4.2.1.12](https://www.rfc-editor.org/rfc/rfc5280).

### Proposed TED-specific acceptance boundary

The project needs a sourced award from an authentic TED publication; it does not claim a qualified signature, legal nonrepudiation or universal document-signing certificate validity. TED itself supplies the signed notice over its authenticated official `pdfs` endpoint and identifies electronically signed published notices as authentic. **A reviewed exact-source acceptance contract is therefore a defensible proposal** independent of claiming the signer certificate conforms to every generic document-signing profile. This is a proposed evidence policy, not an already accepted production decision. [TED's source-authenticity statement](https://ted.europa.eu/en/legal-notice), [official signed download mechanism](https://ted.europa.eu/en/simap/developers-corner-for-reusers).

Such a contract must positively verify the official HTTPS origin and retrieval lineage, exact notice/version and privately retained XML/PDF checksums; whole-file signature math; pinned signer/issuer certificates and observed policy/KU/EKU; current chain and mandatory revocation checks; trusted timestamp; and signed-PDF agreement with the allowlisted extracted lot, organizations, date and value basis. Preserve the EKU mismatch in the private validation receipt. A different source/version/certificate, changed bytes or ambiguous semantic mapping requires a fresh contract. A deterministic inspected contract is not a generic `accepted=true` switch, a new signer allowlist for arbitrary documents, or permission to publish unverified relationships.

The narrow unresolved decision is whether to accept **publisher-authenticated, exact signed TED source evidence with this recorded signer-purpose mismatch**, while making no generic X.509 document-signing claim, or require a source/certificate/preservation chain that also passes that stronger policy. The evidence is ready for that explicit review. Do not present the mismatch as proof that TED's source is forged, and do not report the default nonrepudiation failure as a project prohibition. The current candidate avoids the older chain's historical-expiry problem; its purpose-profile tradeoff remains visible.

### Reproducible receipts

In the same private evidence directory:

- `check_ted_signature_612281.py` / `ted-signature-612281-validation-receipt.json`: archival and with-time results, preserving the older-chain receipt.
- `check_ted_current_signature.py 612281-2026` / `ted-signature-612281-2026-current-receipt.json`: current-time default PDF policy and exact failure.
- `check_ted_digital_signature_diagnostic.py 612281-2026` / `ted-signature-612281-2026-digital-signature-diagnostic-receipt.json`: explicit KU/EKU diagnostic, clearly labelled as distinct from generic document-signing acceptance.

Run each with `uv run --no-project --with pyhanko==0.37.0 python <script> [notice]`. Source documents were never uploaded or modified. No production fact or runtime policy was changed.
