# Working publication delivery

This delivery follows the [accepted definition of done](https://github.com/RicoTrevisan/brussels-wtf/issues/58), with permission correspondence deferred and YouTube retained for milestone two.

## Changes and evidence

- Compare the implementation with main at `6af0ddead942ddb7cd915f38799b04bfe3fc01b9`; the brand-kit change is preserved.
- Correct the sealed eight-meeting/24-item corpus against all nine pinned PDFs. Six item identities and multiple page references were incorrect. The Uccle 2026 budget citation belongs on page 52. Forest newspaper/church items take note of executive decisions; the Ixelles charging item transfers an existing budget allocation into 2026.
- Validate each item identity and operative excerpt within its cited PDF pages. A regression exchanges relevant and unrelated pages while preserving all document text and proves that generic approval text cannot satisfy the contract. Both CI and the production image run actual Poppler extraction.
- Keep corrected source interpretations immutable alongside earlier ones. The same source bytes can support a corrected reading without overwriting the source, old claims or published revision. Changed normalization contracts enqueue a new job rather than being suppressed by old successful-job uniqueness.
- Separate future proposals, past proposals awaiting a documented outcome, and documented decisions using the Brussels calendar date. All three locales retain unknown outcomes until final evidence exists.
- Supply substantive selected-language summaries, expand original-language excerpts and technical checksums on demand, link PDFs to their cited pages, and retain dated publication text plus notices for removed item anchors.
- Add private item-specific corrections using the existing bounded, rate-limited suggestion workflow. Reports never directly change public facts or establish ownership. An authenticated reviewer can mark a report addressed only against a later matching published revision, with an immutable decision audit.
- Add a bounded coverage view for the last 90 and next 30 days, explicitly separating source discovery, publication, final-source gaps and successful official index checks. Archival replay is excluded from fresh checks. The methodology page explains AI/translation labels, responsibility and corrections.
- Preserve item anchors on language changes and search/commune context on return navigation; collapse secondary mobile filters.

## Validation before PR

The full pre-commit suite passed with 389 tests, zero failures and 19 excluded external/browser tests before the final pending-source and same-day label tests. All five browser regression tests pass; all five publication operations tests pass. Both review axes were run, with findings corrected and rechecked. The existing principal-seam tests exercise proposal-to-final publication with immutable revisions; these are isolated integration scenarios, not fabricated production history.

T3Code's Chromium browser reached the local application through the private network. At 390×844 the homepage showed 24 items, no horizontal overflow and collapsed filters. The first item began at y=534. The Fritkot search returned two items; opening an exact item, changing English to Dutch, opening its dossier and inspecting both return anchors retained the correct context and locale. Final post-deployment checks are recorded below only after they actually run.

## Operations and limits

Fresh current-source checks were requested through the authenticated app for all four communes on September 7. Some City downloads retried. Source discovery is not proof of successful extraction or complete publication. The recorded normalizer remains a bounded corpus processor; unsupported new documents require review and additional contracts. No paid generation or transcription is enabled by this work.

Two observed municipal cycles remain an operating follow-up. One rollout cannot establish sustained freshness. Publication timestamps on historical documents represent publication/revision time, never an invented original publication date. Pending permissions are consolidated in the [permission register](https://github.com/RicoTrevisan/brussels-wtf/issues/57).

The interpretation migration preserves rows but changes claim uniqueness. After corrected interpretations have been written, the previous application image is not compatible with the former two-column conflict target: recovery must roll forward or use the operator's verified restore process, not blindly roll back the application. Migration down deliberately refuses to collapse historical interpretations.

## Deployment acceptance

Pending PR, CI, production-image contract, merge, Coolify rollout, corpus replay and live T3Code smoke test. Do not interpret local validation as deployed acceptance.
