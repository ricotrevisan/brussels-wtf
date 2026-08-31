# Belgian Official Gazette legal-person annex access spike

_Status: research note for [Validate Belgian Official Gazette annex access, linking, and excerpt reuse](https://github.com/RicoTrevisan/brussels-wtf/issues/42). Checked 2026-08-31. This is an access/reuse finding, not a domain decision or legal opinion._

## Conclusion and gate

**Keep the Gazette adapter blocked.** The first-party search form is publicly reachable and exposes enterprise-number and publication-number fields, but the official site supplied no documented API, automation limits, reuse licence, excerpt permission, or stable version contract. On 2026-08-31 its search CGI returned HTTP 500 for a POST containing every named control in the current HTML form, with blank optional selects (`akte` and `jvorm`). This observation does not establish that the undocumented CGI accepts this request shape as a supported automated interface. Therefore planned automated retrieval and public excerpt display are not yet shown to be lawful and operationally permitted.

Owner/action: **Rico (operator)** must obtain written confirmation from FPS Justice/Belgian Official Gazette covering automated search and record retrieval, request/rate limits, private evidentiary retention, minimal public excerpts and attribution. FPS Justice must also identify a supported endpoint and immutable record/version or correction model. After that, engineering must repeat the check below and record the response and terms version before enabling an adapter.

## First-party interface and observed behavior

The official FPS Justice/e-Justice [legal-person annex search form][form] posts to `https://www.ejustice.just.fgov.be/cgi_tsv/tsv_rech.pl?language=fr`. Its HTML provides fields named `btw` (enterprise number) and `numpu` (publication number). This is direct first-party evidence that the interactive search supports those keys; it is not evidence that unattended retrieval is permitted.

The prior first-party [exact-result entry point][list] (`list.pl`) returned HTTP 200 with a zero-byte body when called without valid server-side search state. It is therefore not demonstrated to be a durable exact-record locator. The complete-form-control search POST returned HTTP 500 during this check; because the CGI contract is undocumented, this proves only that this attempted request failed, not that the service or interactive browser flow is generally unavailable. No annex record, exact record URL, enterprise number embedded in a record, or byte/version identity could safely be resolved. A locator can also change its bytes and must not be treated as version identity.

No robots result, publicly reachable form, or lack of authentication grants reuse rights. I found no terms linked from the form that state permitted automation, quotas, excerpt reuse, attribution, retention, or bulk access. Silence is a blocker, not permission.

## Reproducible, byte-free check

The dated metadata is retained in the [byte-free observation artifact][observation].

Run:

```sh
scripts/check_gazette_annex_access.sh
```

The script downloads no record to disk and sends response bodies to `/dev/null`. It checks that the official form still advertises the enterprise/publication keys, then submits the non-personal public enterprise number `0403201185` through the documented HTML form shape. It prints only response metadata. As observed on 2026-08-31, the form was HTTP 200 and the POST HTTP 500, so the script exits non-zero with the blocker. It contains no credential and must not be changed to print or commit source bodies.

After FPS Justice supplies a supported exact-record route, extend the check to assert: official HTTPS publisher; exact publication ID; matching normalized ten-digit enterprise number; language and publication timestamp; correction/supersession pointers; and a content hash computed in memory. Print metadata only. Do not persist the record in a fixture until retention permission is recorded.

## Storage, display, attribution, and retention policy

Until written authority is obtained:

| Use | Current rule |
|---|---|
| Private record bytes | **Do not automatically retrieve or retain.** A human may link to the official page during investigation, but this spike does not authorize a snapshot. |
| Retrieval metadata | May store the locator, attempted retrieval time, HTTP status/redirect metadata, and failure; these contain no annex body. |
| Hash/version | Store only after lawful retrieval is confirmed. A SHA-256 identifies bytes but does not itself grant retention or reuse rights. |
| Public display | Link to the exact official record only once a stable exact locator is confirmed. Display no Gazette body or excerpt yet. |
| Excerpt | Blocked. “Minimal necessary” is a proposed ceiling, not permission. Obtain explicit authority and then show only the exact role/action/date fragment needed for the claim. |
| Attribution | If later authorized, label FPS Justice / Belgian Official Gazette, publication ID and publication date, and link to the official record next to every fact. Attribution does not cure missing reuse permission. |
| Retention/mirroring | No public mirror or bulk republication. Set private retention only from the written terms and project evidence policy; deletion must not erase retrieval observations or claim audit records where those may lawfully remain. |
| Personal/private fields | Never publish or use private addresses, signatures, contact details, identity numbers, or family information. |

## Accepted project verifier policy (once access is cleared)

This section does not infer legal or source behavior from the access observation. It records already accepted project requirements from [issue #42][issue], the [Public Evidence Graph and Follow specification][spec-source], and the definitions and privacy limits in [`CONTEXT.md`][context]. Any future source-specific detail not stated there remains a proposal until separately accepted.

Under that accepted project policy, a Gazette publication proves only the operative act expressed in that act:

- `appointment` starts the exact management/governance role on the supported decision/effective date.
- `reappointment` renews or continues the exact role as the act states; it must not silently create a new role or erase the earlier term.
- `resignation` records the person's stated departure; `dismissal` records removal by the competent body. Preserve the source's distinct verb and effective date.
- `cessation` is the generic typed end only when the act supports an end; retain the exact source-native subtype.

Publication date is source metadata, not automatically the decision or effective date. A proposal, agenda, nomination, or future intention is not an operative appointment. A management/governance role is not ownership, shareholding, beneficial ownership, control, or misconduct. An incorporation or old appointment does not prove current status. Current status requires the chronological act set and supported effective dates.

### Accepted fail-closed outcomes

These outcomes implement the issue/spec requirements rather than report behavior observed from e-Justice.

| Condition | Outcome |
|---|---|
| OCR-only text or uncertain character/verb/date | Create a review case; publish no fact. OCR never overrides authoritative text. |
| Missing, invalid, or mismatched CBE enterprise number | Reject entity resolution; create a review case; publish no relationship. Name/address matching cannot repair it. |
| Ambiguous exact role, operative verb, decision date, or effective date | Preserve source observation privately if lawful; emit no verified fact. Never substitute publication date. |
| Proposal or conditional appointment | Emit no appointment fact. |
| Correction | Link it to the corrected publication, apply only explicit corrections, supersede affected status without deleting history, and withhold all affected projections until ordering/scope is clear. |
| Later resignation, dismissal, cessation, or appointment | Close or supersede the earlier current role on the supported effective date; retain dated history. If chronology or identity conflicts, publish nothing pending review. |
| Missing later-act/correction coverage | Do not claim `current`; at most publish the dated historical act when all other rules pass. |
| Layout/language drift or unsupported act subtype | Fail parser validation, create a review case, and publish nothing. |

## Required evidence before unblocking

1. First-party written terms or response explicitly permitting the planned automated request pattern and private evidence retention, with limits and attribution.
2. Explicit treatment of minimal excerpts and public linking; lack of a prohibition is insufficient.
3. A supported exact-record locator and record identity, plus documented correction/version behavior.
4. Successful representative FR and NL checks for valid, invalid, corrected, ambiguous and layout-drift cases, without committing production source bytes.
5. A source-specific verifier implementing every fail-closed rule above.

## Primary sources

- FPS Justice/e-Justice, [Belgian Official Gazette legal-person annex search form][form] (official HTML form and its enterprise/publication-number fields; accessed 2026-08-31).
- FPS Justice/e-Justice, [legal-person annex result entry point][list] (official result endpoint; empty without valid search context during this check; accessed 2026-08-31).

[form]: https://www.ejustice.just.fgov.be/tsv/tsvf2.htm
[list]: https://www.ejustice.just.fgov.be/cgi_tsv/list.pl?language=fr&page=1

[issue]: https://github.com/RicoTrevisan/brussels-wtf/issues/42
[spec-source]: ../specs/public-evidence-graph-and-follow.md#trusted-verifier-contracts
[context]: ../../CONTEXT.md
[observation]: evidence/gazette-access-observation-2026-08-31.md
