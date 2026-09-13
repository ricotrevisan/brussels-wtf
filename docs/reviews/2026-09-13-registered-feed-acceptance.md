# Registered-feed completion reconciliation

Intended branch: `main`, inspected at `cebf268` (Gazette follow-update merge).
[Release reconciliation](https://github.com/RicoTrevisan/brussels-wtf/issues/59)
is closed; the previously reported `4fe56b6` foundation is an ancestor of this
checkout. No foundation needed restoration. This acceptance completes
[the registered-feed integration](https://github.com/RicoTrevisan/brussels-wtf/issues/53)
using the isolated source contract from
[Gazette follow updates](https://github.com/RicoTrevisan/brussels-wtf/issues/49).

## Foundation matrix

All commits below are present in the intended branch's ancestry.

| Reported foundation | Status and commits | Current acceptance evidence |
| --- | --- | --- |
| Citizen accounts and sessions | Present: `f6f85a7` | Citizen authentication domain, route and Chromium tests |
| Registered dossier/person/legal-entity/commune follows | Present: `14259e0`, `3ebf7ac`, merged in `4fe56b6` | `registered_feed_browser_test.exs`: all four follows through public page controls |
| Dossier/person/commune updates and persistent read state | Present: `0bab851`, `25c61fd`, `dde660e`, merged in `4fe56b6` | Same Chromium test: factual dossier correction, later verified mandate, new decisions revision, then a fresh browser session |
| Twelve-month update retention and six-month inactivity with 30/7-day warnings | Present: `e95b617`, `d1709c8`, `3194b95`, `da51129`, merged in `4fe56b6` | `follow_registered_test.exs`, `inactivity_retention_browser_test.exs`; maintenance workers scheduled in `config/config.exs` |
| Private view grants, owner-only controls, accepted transfers | Present: `7289f8c`, `1ffea0f`, `514e9f3`, merged in `4fe56b6`; fresh fixture correction `9f1e62d` | Sharing concurrency/domain tests and `private_collection_sharing_browser_test.exs` |
| Immediate deletion, session revocation, private state removal and cross-citizen isolation | Present: `3ebf7ac`, `514e9f3`, merged in `4fe56b6` | Authentication, registered domain and sharing Chromium tests; deletion rollback/retry and maintainerless-collection refusal |
| Authoritative CBE-bound management update | Public contract present: `0e0d8bc`, merged in `cebf268`; registered integration verified in this change | Gazette registered-feed test plus four-resource Chromium journey |
| Exact commune revision destination | Needed repair: history rendered without the revision ID used in feed URLs | Restored `revision-{id}` on the history section; Chromium requires every followed link's target to exist and be visible |
| Individual unfollow | Remains unimplemented in this slice | Required before broad registered-follow release; tracked separately below |

## Event contract and privacy

The test follows CBE enterprise `0123456749` before running the trusted Gazette
management verifier on the same `appointment.extract.txt` contract used by the
public-update slice. The generated fact ID is both `publicEventId` and the
registered row's `event_identity`. Its localized destination is
`/companies/0123456749?lang={locale}#fact-{fact_id}`. The browser opens the French
fact, checks its manager and official citation, marks all four resource updates
read, signs in in a fresh browser context, and sees the same four read rows.
Stored delivery URLs use the citizen's preferred locale; rendered links use the
selected page locale.

The registered integration also proves that retrieval/extraction and unverified
candidates do not deliver; unchanged extraction, fact recording, verification and
synchronization deliver no duplicate and preserve read state. A verifier-rejected
candidate stays in private unreviewed work. Retiring the verified subject makes
the public gate exclude the fact and removes the previously delivered row on
read. Another citizen cannot read the feed or mark its update read. The payload
has only public event metadata; fixture private identity fields and review
content remain absent. The four-resource browser test also excludes
municipal typography-only changes.

These are synthetic, isolated test fixtures, not real published company claims.
This change does not activate Gazette acquisition, publish fixture facts, or
change source-specific activation conditions in
[the source register](https://github.com/RicoTrevisan/brussels-wtf/issues/57).
No email notification transport is introduced; account sign-in and inactivity
warnings remain the existing account lifecycle messages.

## Repeatable verification and release boundary

Run against a dedicated local test database:

```sh
ERL_FLAGS='+S 4:4' MIX_TEST_PARTITION='_issue53' mix test
ERL_FLAGS='+S 4:4' MIX_TEST_PARTITION='_issue53' mix test.browser
ERL_FLAGS='+S 4:4' MIX_ENV=test mix compile --warnings-as-errors
ERL_FLAGS='+S 4:4' mix format --check-formatted
```

The browser alias includes personal feed, citizen authentication, all four
registered targets, inactivity retention, and private collection sharing/deletion.
External storage, production-image and live-corpus suites are separate and are
not claimed by this isolated integration acceptance.

**Broad release remains blocked by
[Add individual unfollow controls for registered citizens](https://github.com/RicoTrevisan/brussels-wtf/issues/54).**
Completing this event integration does not waive that requirement or constitute
production rollout acceptance.
