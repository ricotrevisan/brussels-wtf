# TED extraction and correction preparation

This is preparation for [Publish one TED contract award end to end](https://github.com/ricotrevisan/brussels-wtf/issues/47), not its public acceptance. No TED fact is verified, stored or published by this change.

## Implemented boundary

`BrusselsWtf.TED.AwardNotice.parse/2` extracts one explicitly selected lot from bounded eForms result XML. It follows the result, tender, settled-contract and tendering-party references. It retains complete organization identifiers for later CBE resolution. It never infers the enterprise number from an underscore prefix.

The amount is exclusively the winning tender's `LegalMonetaryTotal/PayableAmount` (BT-720), in EUR. The date is the linked settled contract's `IssueDate`. Neither a notice aggregate, framework ceiling nor a generic placeholder award date supplies those fields. Missing, ambiguous, withheld or unsupported selected fields fail closed. A no-winner result contains no award payload.

`BrusselsWtf.TED.CorrectionChain.select/1` orders an explicitly supplied complete chain, preserving predecessors and selecting its terminal result. Gaps, forks, cycles, duplicate source identities, mixed procedures/lots/buyers and backwards publication dates fail closed. Cancellation never falls back to an earlier winning result. This function **cannot establish that a search was complete**; acquisition must independently discover versions and reverse correction links and retain its receipts.

## Actual-source isolated checks

The private January/March Ixelles XML pair produces:

- [22171-2026](https://ted.europa.eu/en/notice/22171-2026/xml), LOT-0002: no award.
- [181194-2026](https://ted.europa.eu/en/notice/181194-2026/xml), LOT-0002: one winning tender, €54,192.04, contract conclusion 5 March 2026, explicit predecessor UUID/version retained.

The newer [City of Brussels result 612281-2026](https://ted.europa.eu/en/notice/612281-2026/xml), LOT-0001, extracts €4,129,220 and contract conclusion 31 August 2026. The complete identifiers remain `0207373429_4620` and `0434042237_33f448a8-4ee6-4d82-858e-726222f370f8`. The licensed CBE adapter independently returns active legal persons Ville de Bruxelles (`0207373429`) and ROAD SWEEPER RENTING (`0434042237`) from release `cbe-open-data:470:2026-09-01:1.0.0`, archive SHA-256 `afbc36d006b123d0426fe6f106afb1023ae1fe017cd4b514d2167f3551f41b49`. This is an inspected mapping proposal, not a generic Belgian suffix rule.

At the recorded read-only check, TED returned one version of the Brussels notice UUID and no notice with its UUID/version as `change-notice-version-identifier`. These time-bounded search receipts are private; they must be refreshed before publication. No correction history is invented for this notice.

The [signature and identity research](../research/ted-ixelles-award-contract-2026-09-16.md) distinguishes mathematical signature integrity, trusted timestamp, certificate-policy limitations and source-specific authenticity. An extraction success does not settle that publication gate.

## Verification

The normal tests use authored XML. Optional `external` tests read previously retained official files; they perform no acquisition and make no production changes:

```sh
TED_EVIDENCE_DIR=/path/to/private/retained/notices \
  MIX_TEST_PARTITION=real_evidence \
  mix test --include external \
  test/brussels_wtf/ted_award_notice_test.exs \
  test/brussels_wtf/ted_correction_chain_test.exs
```

## Remaining release and publication gates

1. Resolve and review the exact signed-source authenticity contract; retain the full certificate-policy findings without claiming qualified signing or generic document-signing trust.
2. Integrate bounded acquisition/versioning and correction-search receipts with immutable source provenance. Reject unknown later corrections and open review cases.
3. Bind the exact inspected raw identifiers to actual CBE records; provision the already licensed release for the production adapter using the existing access path.
4. Add TED-specific trusted verification, typed award fields, supersession/idempotency and both public organization projections, retaining all existing publication gates.
5. Run the acquisition → verification → both-page seam, negative exposure tests and FR/NL/EN browser acceptance in isolation. Prepare the exact deployment and one-award publication procedure for scoped authorization.

The real mandate acceptance remains separate: [Gautier Calomne's dated Ixelles declaration](https://brussels.wtf/people/01a0a73a-d14a-7676-9baa-128c7bc2b281?lang=en#fact-01a0a73a-d150-7c37-832e-b37a69ca2a25) is live on release `59fd2999d602eb4e25005a7181387380a52c8d06`. This TED preparation neither changes that fact nor activates Gazette evidence.
