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

PR [69](https://github.com/RicoTrevisan/brussels-wtf/pull/69) merged as `5f83ff5b583c1e1656d11ea1fa8c18eed2b1aa5c`. Both PR and main CI passed, along with 391 pre-commit tests, five browser tests, and four PDF/OCR contracts on the exact merged image. The one-CPU / 1-GiB OCR case passed an isolated reproduction and the full repeated contract after one earlier process kill.

Coolify app deployment `e0wlhzuidoikb7a7atxlh6gd` passed readiness, migrations, archive and PDF-tool validation. OCR deployment `mzjizqakh8nzvziikyg8ykyn` reused the app image. Inspection of the running app and Compose worker proved the same image ID: `sha256:ef6404c291e43868f586abc4ff90005f12aa5c21e185b04cbdab0a45562a7893`. Earlier OCR verification commands failed because Coolify adds a timestamp to container names and detects Compose flags across the whole custom command; the successful command uses explicit Compose file flags and `docker compose images --format json`.

All nine official source URLs returned PDFs. Audited retries resolved the Uccle marker failure and two historical Ixelles native-extraction failures. Five obsolete publication generations were diagnosed against their retained inputs: they included historical item keys outside the corrected sealed selection. Their audit corrections identify that obsolete scope and preserve the failed inputs; the separate scoped publication still had to pass its normal evidence and locale gates.

Corpus batch `01a07de1-666f-79ab-9f79-5ee206235a70` restored eight meetings and 24 public anchored items. Live smoke testing then found two follow-up defects: the coverage view crashed on a discovered source without a normalized meeting, and corpus completion counted historical failed runs instead of the runs supporting current revisions. Regression coverage now includes both production states and an already-published corpus replay.

The final deployed commit, follow-up deployment IDs and browser acceptance are maintained in the canonical [delivery issue](https://github.com/RicoTrevisan/brussels-wtf/issues/58). This document records the first rollout and the defects that its smoke test exposed; it does not substitute that first rollout for final acceptance. Sustained observation is tracked in [the two-cycle operating follow-up](https://github.com/RicoTrevisan/brussels-wtf/issues/70).
