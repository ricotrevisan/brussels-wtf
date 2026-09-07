# Live product and GitHub backlog review — 7 September 2026

## Accepted follow-up and executable backlog

Rico accepted the review with two changes: defer permission/licence requests until the app works, and retain YouTube as a key next-milestone feature. These decisions supersede the original recommendations below to close YouTube or make the outstanding Gazette correspondence block all development.

- [Working-publication milestone](https://github.com/RicoTrevisan/brussels-wtf/milestone/1), with the [delivery map and definition of done](https://github.com/RicoTrevisan/brussels-wtf/issues/58).
- [Next milestone: YouTube, evidence graph, and following](https://github.com/RicoTrevisan/brussels-wtf/milestone/2). The [YouTube issue](https://github.com/RicoTrevisan/brussels-wtf/issues/55) remains open with official meeting matching/playback and a bounded bilingual transcript pilot.
- [Single permission/licence register](https://github.com/RicoTrevisan/brussels-wtf/issues/57): request owners, official contact routes, intended uses, existing approvals and later activation checks. Requests are deferred; no external messages have been sent. Isolated fixture development does not wait for unresolved correspondence, while synthetic facts remain outside public coverage.
- CBE registration/licence/authenticated access was already completed on September 2 according to the later comment in its source issue. Ixelles mandate authorization was already recorded on September 4. Neither requires a repeat request for the accepted scope.
- Implementation slices: [release reconciliation](https://github.com/RicoTrevisan/brussels-wtf/issues/59), [temporal status](https://github.com/RicoTrevisan/brussels-wtf/issues/60), [coverage freshness and gaps](https://github.com/RicoTrevisan/brussels-wtf/issues/61), [substantive explanations](https://github.com/RicoTrevisan/brussels-wtf/issues/62), [multilingual reading](https://github.com/RicoTrevisan/brussels-wtf/issues/63), [verification and corrections](https://github.com/RicoTrevisan/brussels-wtf/issues/64), and [mobile reading](https://github.com/RicoTrevisan/brussels-wtf/issues/65).

The remainder records the original inspection and proposed rationale. Current issue bodies and the accepted follow-up above govern delivery where the recommendations differ.

## Assessment

brussels.wtf has a working public foundation: real municipal material, all four communes, language selection, search/filtering, individual agenda-item links, explicit proposal/decision states, and authoritative citations. The live experience is an early public reading alpha. It does not yet demonstrate a dependable, current civic publication that saves residents the work of reading municipal documents.

The main product gap is the distance between finding a title and understanding what happened, why it matters, and what changed since the previous meeting. Evidence graphs and personal feeds remain approved directions, but their value depends on useful, current coverage underneath them.

An engineering completion percentage would be misleading. This review assesses public outcomes, not the completeness of the ingestion system or private editorial tools.

## Method and limitations

Inspected the live homepage in a real Chromium browser at 1280×800 and 390×844, all six linked meeting pages in English, French/Dutch homepage variants, the Dutch Ixelles proposal, search results, commune filtering, source-link markup, and the documented missing corpus/dossier routes. Four sampled official PDF origins returned HTTP 200 with PDF content types on HEAD requests. This verifies reachability, not the truth of every claim or current byte identity.

Read all nine open GitHub issues, their comments, native parent/sub-issue and blocking relationships, the closed issue index, and selected closure/decision records. Compared production's release identifier with GitHub main. No authenticated editor/citizen flows, production logs/database, paid generation, or municipal cycle monitoring were exercised. No GitHub issues were changed.

Source observations are dated to this review. Proposed priorities, service targets, and acceptance criteria below are recommendations rather than accepted product decisions.

## Live findings

| Reader outcome | Observed evidence | Assessment and action |
| --- | --- | --- |
| Find relevant municipal activity | The [homepage](https://brussels-wtf.nocode-to-knowcode.com/) exposes 16 agenda items across six meeting pages and all four communes. Searching `Fritkot` returns the two related City items; filtering Uccle returns three Uccle items. | Working foundation. Keep the concise text-first approach and existing search/filter functionality. |
| Understand what is upcoming | All seven entries under “Coming up” have June/July 2026 meeting dates, already past on 7 September. [City June 8](https://brussels-wtf.nocode-to-knowcode.com/meetings/city-of-brussels/2026-06-08?lang=en) still uses future-tense consideration wording. | High-priority trust defect. Separate future meetings, past meetings with undocumented outcomes, and documented decisions. Absence of final evidence cannot establish that the council has not considered an item. |
| Know how complete/current coverage is | No visible last-checked or coverage-completeness explanation. Latest displayed meeting is July 2; Uccle coverage shows June 2025. Observed page revisions are August 21. | Readers cannot distinguish a deliberately limited sample, a municipal publication delay, and a stalled pipeline. Those dates alone do not prove polling is broken. Publish coverage scope and operational freshness separately. |
| Understand a decision | [Forest March 24](https://brussels-wtf.nocode-to-knowcode.com/meetings/forest/2026-03-24?lang=en) has three decision items whose explanatory bodies repeat a generic approval statement. [Uccle June 26](https://brussels-wtf.nocode-to-knowcode.com/meetings/uccle/2025-06-26?lang=en) similarly names a charging-point tax without explaining its operative provisions. | Status reporting works; substantive explanation is weak. Explain the actual action, relevant amounts/locations/timing/conditions when sourced, and what remains unknown. A headline plus approval boilerplate is insufficient. |
| Read independently in the selected language | [Ixelles 268 in English](https://brussels-wtf.nocode-to-knowcode.com/meetings/ixelles/268?lang=en) leaves the specific grant amount and recipient in a French blockquote; [Dutch](https://brussels-wtf.nocode-to-knowcode.com/meetings/ixelles/268?lang=nl) does the same and retains English source/provenance labels. | Localized navigation/headlines exist, but the selected-language explanation is incomplete. Original-language excerpts are useful if explicitly identified and accompanied by a faithful translation. |
| Follow a matter through time | Both City items name OPP/2026/185, but neither offers a dossier link. The [documented dossier URL](https://brussels-wtf.nocode-to-knowcode.com/dossiers/city-opp-2026-185-fritkot-socles?lang=en) returns 404. | A core product promise is unavailable in the observed journey. Restore the existing accepted corpus/dossier outcome before adding a new graph feature. |
| Verify a claim easily | Every inspected item has an official-source link, page/section locator, retrieval timestamp, and hash. Sampled origins are reachable. Links open the PDF without a page fragment, including a 483-page Ixelles document. Hashes dominate some mobile evidence blocks. | Strong traceability affordances, high verification effort. Use meaningful source titles and best-effort page links; retain accessible textual locators. Keep technical provenance in expandable details. |
| Correct or contextualize coverage | The inspected meeting pages show a revision timestamp and byline, but no reader correction link, revision-history navigation, or methodology/about entry point. | Provide a visible accountability route and explain authorship, AI/translation labels, scope, and correction handling. Do not infer that private correction infrastructure is absent. |
| Read comfortably on a phone | At 390px there is no homepage horizontal overflow. In Dutch, the first article starts around y=641; the expanded filter form occupies most of the first viewport. Long titles share a row with wide date/commune metadata. | Responsive but inefficient. Collapse secondary filters and place metadata below titles at narrow widths. A visual redesign is less urgent than content/status fixes. |

## Delivery records need reconciliation

[Publish a bounded real-meeting browsing corpus](https://github.com/RicoTrevisan/brussels-wtf/issues/33) is closed with a report of eight meetings, 24 anchored items, and a verified continuing dossier. Production exposes six/16 through its homepage. The documented [Uccle April 23](https://brussels-wtf.nocode-to-knowcode.com/meetings/uccle/2026-04-23?lang=en) and [Forest April 22](https://brussels-wtf.nocode-to-knowcode.com/meetings/forest/2025-04-22?lang=en) routes return 404, as does the dossier. Ixelles 268 exposes one selected item rather than the three-item corpus target.

The [production version endpoint](https://brussels-wtf.nocode-to-knowcode.com/health/version) reports `c6045e8114ccd0182bbeffe2bff46fcdfd47d74b`, exactly the current GitHub main head. The corpus merge `29b547c` is an ancestor of that head. This is not evidence that simply deploying current main will restore the corpus; import state, publication gates, configuration, and later changes need examination.

[Build the public evidence graph and follow product](https://github.com/RicoTrevisan/brussels-wtf/issues/40) links an approved specification at `docs/specs/public-evidence-graph-and-follow.md`, but the GitHub contents API returns 404 and the current main specs directory only contains the MVP spec. Several later closed issues report completed account/follow work; the commit prefix `4fe56b6` cited in the personal-feed completion comment could not be resolved by the compare API. That is a discrepancy to investigate, not proof that the work never existed or was intentionally discarded.

Require future completion evidence to distinguish: implemented, merged into the intended branch, configured/imported, and demonstrated on the target deployment. Do not put commit identifiers or operational diagnostics into ordinary reader flows.

## Disposition of every open issue

Prefer closing obsolete work with a reason over deleting issue history. There is no evidence-based reason to permanently delete any existing issue.

| Existing issue | Recommendation | Concrete improvement |
| --- | --- | --- |
| [Add YouTube as a source?](https://github.com/RicoTrevisan/brussels-wtf/issues/55) | Close as not planned for the next milestone, preserving it as an idea. | It currently supplies only a channel URL and no reader outcome. If revived, specify a bounded recording-discovery/linking slice with official-channel identity, meeting matching, and clearly supplementary status. Transcription needs its separately accepted bilingual benchmark; video cannot establish final outcomes under the current policy. |
| [Build the public evidence graph and follow product](https://github.com/RicoTrevisan/brussels-wtf/issues/40) | Keep and improve. | Restore the authoritative linked spec and distinguish specification completion from product completion. Record phases for source facts, useful contextual presentation, and following. Keep native children, but make the next milestone measurable in reader journeys. |
| [Publish one Gazette management fact end to end](https://github.com/RicoTrevisan/brussels-wtf/issues/45) | Keep blocked. | The closed access spike explicitly leaves permission/access unresolved. Create an open owner-action blocker; closed research alone must not imply operational readiness. Attach accepted source/identity prerequisites and add a real municipal context for the eventual public demonstration. |
| [Publish one Brussels public mandate end to end](https://github.com/RicoTrevisan/brussels-wtf/issues/46) | Keep as the first candidate graph source after reconciliation. | The September 4 comment records authorization, so do not request it again. Put that resolved status and the precise allowed reporting-period fields into the issue body. Reconfirm the implementation/spec/CBE foundation on current main before retaining `ready-for-agent`. Demonstrate a discoverable public person page and an exact citation without asserting participation in unrelated council matters. |
| [Publish one TED contract award end to end](https://github.com/RicoTrevisan/brussels-wtf/issues/47) | Keep, lower immediate priority, improve readiness. | Access research is accepted, but explicitly verify the operational CBE identity spine. Resolve the recorded value-field/value-basis and identifier-mapping details. Prefer a fixture tied to a supported commune or a defensibly linked local matter; a valid unrelated award proves a verifier, not Brussels reader value. Do not require a nonexistent local notice or treat below-TED gaps as evidence of no contracts. |
| [Render a cited two-edge fact path on a meeting item](https://github.com/RicoTrevisan/brussels-wtf/issues/48) | Keep, defer until useful meeting coverage and the source fact exist. | Add an actual navigable meeting → named entity → sourced role example in all languages. Explain each dated role in plain language. Preserve the approved neutral vocabulary and absence of inferred influence; do not silently substitute a mandate fact for the Gazette dependency. |
| [Emit a follow update from a verified management fact](https://github.com/RicoTrevisan/brussels-wtf/issues/49) | Keep its narrow technical scope. | Its blocker on the Gazette fact is real. Pin the public event/read-model contract and make the eventual feed acceptance test consume the same exact fact/revision. Keep private/unverified changes excluded. |
| [Sync a registered personal feed and enforce deletion/retention](https://github.com/RicoTrevisan/brussels-wtf/issues/53) | Narrow to the remaining gap after verifying current branch state. | Its comment reports most account/feed/privacy work complete, with the legal-entity projection as the remaining blocker. Replace the apparently all-new build checklist with a completion matrix and exact remaining acceptance. If that code is missing from the intended branch, track restoration explicitly. Use the native blocker on the event issue; `needs-info` should describe actual missing information rather than merely unfinished dependency work. |
| [Add individual unfollow controls for registered citizens](https://github.com/RicoTrevisan/brussels-wtf/issues/54) | Keep and decouple where justified. | Follow removal should not wait for an unrelated company-update producer if the registered follow foundation is operational. Replace the blanket dependency on the entire feed issue with the actual persistence/auth prerequisite. Decide retained read-history behavior and make unfollow a launch gate for registered following. Never expose a durable follow journey without its reversal. |

The [follow-semantics decision](https://github.com/RicoTrevisan/brussels-wtf/issues/38) explicitly reopened the initial MVP boundary. Accounts and following therefore are approved scope, not automatically deletable because the older MVP excludes them. This review recommends sequencing them behind useful publication, not reversing that decision.

## Reopen existing work

Reopen [Publish a bounded real-meeting browsing corpus](https://github.com/RicoTrevisan/brussels-wtf/issues/33) with the dated six-meeting/16-item/404 reproduction and an explicit deployed acceptance check. Retain its existing eight-meeting, 24-item, multilingual, budget, evidence, and dossier criteria. Inspect import/gate failures before proposing new ingestion code. Completion must include opening the cross-meeting dossier from both City agenda items and returning to their exact anchors in each locale.

Keep the completed polling, multilingual, correction, and dossier foundations closed unless diagnosis establishes their original acceptance actually failed. Create focused new slices for the live gaps rather than reopening every infrastructure issue.

## Proposed new issues

Priority here is proposed ordering, not a new GitHub triage-label vocabulary. Apply canonical labels only. A proposed product decision is not `ready-for-agent` until its behavior and dependencies are settled.

### A. Reconcile current main, live release, and recorded feature completion — P0

**Problem:** Live main agrees with production, yet linked specifications and reported later feature completion cannot be located there.

**Acceptance:** Record intended branch/release; account for the missing graph/follow spec and completion commits; produce a feature matrix distinguishing current code, configuration/data, and live journeys; recover only the intended accepted work; record explicit decisions for any intentionally superseded work; provide a repeatable release acceptance checklist that proves public routes and corpus availability. Link the corpus reopening separately so source-code reconciliation does not become an unbounded repair ticket.

**Readiness:** `needs-triage`; investigation can begin immediately. This assessment does not authorize deployment, history rewriting, or paid generation.

### B. Separate upcoming meetings from past proposals with unknown outcomes — P0

**Acceptance:** Using Europe/Brussels meeting dates, future meetings appear as upcoming, past proposal-only items say the final outcome is not yet documented in this publication, and sourced decisions retain their actual disposition. A missing final record never implies a meeting has not happened. Homepage and meeting copy agree in FR/NL/EN; crossing the meeting date changes temporal presentation without inventing a decision or altering historical source claims. Cover the date boundary and a later authoritative final record. Recommend a distinct “Awaiting documented outcome” group or equally explicit item status; settle the presentation choice before implementation.

**Readiness:** `needs-triage`; accept temporal presentation, then `ready-for-agent`.

### C. Demonstrate current coverage and disclose coverage gaps for every commune — P1

**Acceptance:** For a bounded current publication window, compare official indexes with what the site covers; account for meetings/items included and omitted; distinguish partial selection, source unavailable, processing/review delay, and no published meeting. Show reader-facing coverage scope and last source-check time separately from page revision time. Exercise subsequent official changes through dated multilingual revisions and record acquisition-to-publication lag over two observed municipal cycles. Propose a 24-hour publication target for eligible new material, subject to measured capacity and accepted budget; record exceptions visibly to the operator. Do not imply that an empty result means no council activity. Paid calls retain explicit generation mode, allowed scope, and hard budget controls.

**Dependencies:** Existing polling/publication foundations and restored corpus acceptance. Diagnose those systems before rebuilding them. `ready-for-human` for service/budget decisions, followed by an executable implementation slice.

### D. Make coverage explain the actual municipal action — P1

**Acceptance:** On a bounded sample spanning proposals and decisions in every commune, replace boilerplate with a concise explanation of the action, affected public service/place/group, relevant amount and basis, effective date/conditions, and next documented step, wherever supported by evidence. Explain unfamiliar administrative wording; explicitly separate missing information. Every added factual clause retains an applicable source reference. A reader can answer what was proposed/decided and what remains unknown without opening a PDF. Validate editorial usefulness on representative readers before scaling; do not manufacture significance or demand unavailable fields.

**Readiness:** `ready-for-human` for the initial editorial examples and acceptance rubric; engineering follows the accepted examples. This can progress alongside source freshness.

### E. Complete multilingual reading and preserve language-switch context — P1

**Acceptance:** EN/NL readers get the same substantive facts as FR, including the Ixelles grant amount and recipient. Label original-language quotations, provide faithful selected-language explanation/translation, and mark quote language for assistive technology. Localize source/provenance labels where intended without changing their meaning. Language switches retain the exact agenda-item anchor and current filter/query context. Factual changes continue to publish as synchronized variants with dated history.

**Readiness:** `needs-triage`; define the quotation/translation treatment, then `ready-for-agent`. Coordinate with D without creating a dependency on a complete editorial overhaul.

### F. Make source verification and factual correction accessible from each item — P1

**Acceptance:** Give source links meaningful document titles, a visible page/section locator, and best-effort PDF page fragments; keep retrieval/hash metadata accessible under details. Clearly distinguish publication revision, source date, and retrieval date. Provide a stable item-specific correction entry point that creates private actionable review work, never publishes submitted allegations, and explains the disposition. Add a linked methodology/scope/author explanation covering generation and translation labels. Surface existing revision/correction history when present. Prove the journey on mobile and in all three languages, reusing the current review machinery where appropriate.

**Readiness:** `needs-triage`; scope private correction intake and retention against existing policy before autonomous implementation. Avoid replacing the working evidence archive or creating an account requirement for reading.

### G. Put useful coverage ahead of secondary mobile controls — P2

**Acceptance:** At narrow widths, show a meaningful first item sooner using a compact commune selection and collapsible secondary filters; put date/commune below long titles. Preserve search/filter behavior, keyboard labels/focus, no-JavaScript reading, and no horizontal overflow. A meeting reader can return to the prior filtered list without losing selection. Check FR/NL/EN at 390px and desktop; preserve the text-first visual direction.

**Readiness:** `needs-triage`, then `ready-for-agent` after the compact layout choice. This should remain a small usability slice.

### H. Resolve the outstanding Gazette acquisition/reuse prerequisite — graph prerequisite

**Acceptance:** Assign Rico the specific unresolved request described in the closed access spike, retain the authoritative response in the private record, and record allowed acquisition/retention/link/excerpt behavior. After approval, rerun the existing access check and prepare the required pinned fixture; if denied, record a scoped alternative or an explicit not-planned disposition. Do not treat a completed investigation as permission.

**Readiness:** `ready-for-human`. Add it as an open native blocker for the Gazette implementation issue; the fact-path and management-update chain remains downstream. This is an existing recorded blocker, not a new legal review of already authorized mandate work.

## Recommended delivery sequence and success measures

1. Reconcile the intended release, restore the accepted browsing corpus/dossier, and fix temporal status. Acceptance includes the actual target URL, not only passing local tests.
2. Deliver one complete recent meeting per commune with meaningful multilingual explanations, an honest coverage statement, and usable citations. Choose a bounded current window; do not solve freshness by importing an unlimited archive.
3. Demonstrate one real proposal-to-final-record revision and one cross-meeting dossier journey. Measure publication delay and failures over two real cycles.
4. Validate with a small set of residents/journalists: can they find their commune, explain one relevant action and its status, locate its evidence, and see what changed? Proposed target: at least four of five participants complete these tasks unaided. This is a formative usability check, not statistical proof of demand.
5. Resume one relevant evidence-graph source and the existing follow roadmap. Use public, useful updates to prove a reason to return; finish unfollow before making registered following broadly discoverable.

Track freshness, explicitly accounted-for coverage, reader comprehension, evidence-verification success, and continuity across meetings. Counts of closed issues or extracted documents alone cannot establish that the publication meets its purpose.
