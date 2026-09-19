# brussels.wtf MVP Implementation Specification

## Problem Statement

Residents, journalists, civic organizations, and council participants currently have to monitor four different municipal publication systems to understand what the councils of Ixelles, Uccle, Forest, and the City of Brussels intend to discuss and what they ultimately decide. Those systems publish different combinations of HTML indexes, agendas, explanatory notes, supporting dossiers, supplements, addenda, minutes, registers, votes, livestreams, and recordings. Their naming and versioning conventions are inconsistent; some replace bytes at an existing URL; some retain multiple versions; some publish final records months later; and none provides one dependable structured feed across the four communes.

A reader cannot safely treat an agenda as a final decision, infer that an item disappeared or passed, or rely on a filename or URL as evidence of a stable document version. The publication therefore needs to preserve exactly what was observed, distinguish proposals from documented decisions, keep every public factual claim traceable to authoritative evidence, and surface acquisition or interpretation ambiguity for review rather than silently guessing.

The publication also needs to explain the same municipal activity in French, Dutch, and English without allowing stale or incomplete language variants to diverge. It must make continuing matters understandable across meetings through dossiers while retaining the meeting-specific wording and outcome of each agenda item. Public corrections, uncertain dossier links, and processing failures need an actionable editorial workflow that is independent of background-job transport state.

Company, person, management, ownership, public-mandate, contract, and council-member relationship coverage introduces separate evidentiary and privacy risk. Name similarity, textual mentions, model inference, or a shared address cannot become a public relationship. Public relationship facts may publish automatically only after their source-specific identity, authoritative-evidence, wording, and privacy rules pass.

The MVP must run within Rico's existing Hetzner/Coolify estate and its constrained host capacity. It must reuse the existing PostgreSQL and rustFS services through dedicated logical namespaces, avoid unbounded OCR or transcription work, and avoid taking responsibility for estate-wide backup, retention, or restore operations.

## Solution

Build one production Phoenix application using Ash for domain behavior, Dstar for application integration, PostgreSQL for structured state and Oban jobs, and a private rustFS bucket for immutable source bytes and derived artifacts. Four explicit commune adapters will discover authoritative municipal source locators. Every check will create a retrieval observation; every new byte sequence will create an immutable, SHA-256-identified source version; and every extraction or normalization attempt will retain processor provenance and quality measurements.

The ingestion pipeline will poll authoritative indexes, retrieve and archive sources, extract born-digital text with Poppler, route only failed page-level extraction through bounded OCRmyPDF/Tesseract processing, normalize source material into council meetings, agendas, agenda items, proposals, decisions, evidence, and dossiers, generate complete French, Dutch, and English locale variants, and publish a meeting page automatically only when its locale and claim-specific evidence gates pass. Deterministic failures and ambiguities will create review cases rather than retry indefinitely or mutate raw evidence.

The public experience will use a dense, text-first timeline. The homepage will show separate `Coming up` and `What they decided` sections across the reader's selected communes. Entries will open the relevant agenda-item anchor on a stable meeting page. Meeting pages will clearly identify proposals, unknown outcomes, and final decisions; cite authoritative sources; show applicable content provenance; and link to continuing dossier timelines. Language will be selected through an optional BCP 47 `lang` query parameter while the resource path remains stable.

An authenticated review inbox will expose actionable acquisition, extraction, normalization, evidence, suggestion, and link-correction cases. Reviewers will compare immutable source context with extracted and normalized content, add notes, and invoke explicit audited actions such as retry, reclassify, relink, correct, merge, split, confirm, reject, or mark unsupported. Review actions will create new observations, artifacts, processing generations, or domain revisions; they will never alter an immutable source version.

Identity and relationship foundations will use CBE enterprise numbers for legal entities, corroborated identities for people, and typed, time-bounded relationship claims backed by evidence. Company enrichment will run asynchronously and will not block neutral meeting-page publication. Public company/person routes may expose only facts that pass the automated relationship evidence and privacy rules.

Production will reuse the Coolify-managed PostgreSQL and rustFS services. The application will receive a dedicated database and least-privilege role plus a dedicated private bucket and bucket-scoped credentials. Releases will migrate application-owned schemas and validate storage access, but will not provision cluster-level resources, deploy replacement storage services, or implement an application-owned backup system.

## User Stories

### Readers and public discovery

1. As a Brussels resident, I want to see recent and upcoming council coverage across all four MVP communes, so that I can understand local government activity without visiting four publication systems.
2. As a first-time reader, I want all four communes selected by default, so that I do not unknowingly miss relevant coverage.
3. As a returning reader, I want my commune selection remembered in my browser, so that the homepage remains relevant without requiring an account.
4. As a reader, I want `Coming up` and `What they decided` to be separate sections, so that proposals are never mistaken for final outcomes.
5. As a reader, I want each timeline entry to identify its commune and meeting date, so that I can place the matter in municipal context.
6. As a reader, I want each timeline entry to identify the agenda-item number when one is authoritative, so that I can compare coverage with the municipal record.
7. As a reader, I want a concise factual summary on each timeline entry, so that I can decide what to read in depth.
8. As a reader, I want each timeline entry to label the matter as a proposal, an unknown outcome, or a documented decision, so that procedural state is explicit.
9. As a reader, I want final decisions to state the documented disposition, so that approval, rejection, amendment, postponement, withdrawal, and other sourced outcomes are not conflated.
10. As a reader, I want minimal imagery and a dense text-first layout, so that I can scan substantial civic information efficiently.
11. As a reader, I want a timeline entry to open the relevant agenda-item anchor within its meeting page, so that I arrive at the exact matter without creating a detached article history.
12. As a reader, I want agenda-item anchors to remain stable as the meeting page gains final records and corrections, so that bookmarks and citations continue to work.
13. As a reader, I want authoritative source citations near factual claims, so that I can verify the publication's account.
14. As a reader, I want public citations to link to authoritative municipal origins rather than the private archive, so that evidence remains verifiable without exposing private storage.
15. As a reader, I want source retrieval times and checksums available where useful, so that I can distinguish evidence versions even when a municipality reuses a URL.
16. As a reader, I want applicable `AI-generated`, `machine-translated`, and `human-reviewed` labels, so that I understand how the text was produced.
17. As a reader, I want official sourcing communicated through citations rather than a redundant badge, so that provenance labels retain a precise meaning.
18. As a reader, I want public coverage to omit a personal byline, so that the civic information remains the focus.

### Multilingual reading

19. As a French-speaking reader, I want a complete French representation of every published meeting page, coverage item, and dossier, so that I never encounter partial language fallback.
20. As a Dutch-speaking reader, I want a complete Dutch representation of every published meeting page, coverage item, and dossier, so that coverage is usable in Dutch.
21. As an English-speaking reader, I want a complete English representation of every published meeting page, coverage item, and dossier, so that coverage is accessible beyond the two municipal source languages.
22. As a reader, I want the same stable resource path in every language, so that changing language does not create competing identities for one resource.
23. As a reader, I want an explicit valid `lang` query parameter to take precedence, so that a shared link opens in the intended language.
24. As a returning reader, I want my persisted language selection used when a link has no explicit language, so that the site remembers my preference.
25. As a first-time reader, I want browser language preferences considered when no valid language is explicit, so that the initial experience is likely understandable.
26. As a reader with no matching preference, I want English used as the final fallback, so that locale resolution is deterministic.
27. As a reader, I want an invalid or unsupported language value handled predictably without changing the resource identity, so that malformed links do not expose mixed-language content.
28. As a reader, I want factual corrections to update French, Dutch, and English together in one revision, so that languages do not disagree on facts.
29. As an editor, I want typography-only corrections to affect one locale when appropriate, so that harmless language-specific fixes do not force factual revision work.
30. As an editor, I want French to remain the canonical editorial text for the MVP, so that generation and correction workflows have one declared source of editorial intent.
31. As an editor, I want source evidence to retain its original French, Dutch, or bilingual language, so that editorial canonical language does not rewrite source provenance.

### Meetings, agendas, decisions, and dossiers

32. As a reader, I want one meeting page per council meeting, so that upcoming material and later final outcomes remain part of one understandable record.
33. As a reader, I want dated revisions on an evolving meeting page, so that I can see when upcoming coverage became final coverage or was factually corrected.
34. As a reader, I want each coverage item to correspond to one meeting-specific agenda item, so that wording, order, evidence, and outcome remain tied to the correct meeting.
35. As a reader, I want supplements to update an existing agenda item only when an authoritative identifier proves continuity, so that similar text is not silently merged.
36. As a reader, I want a newly added matter to create a separate agenda item, so that additions remain visible rather than overwriting the base agenda.
37. As a reader, I want in-session additions found only in final records to appear as agenda items with final evidence, so that the published meeting record is complete.
38. As a reader, I want a proposal stored and presented separately from a decision, so that planned action is not reported as adopted action.
39. As a reader, I want an agenda item's outcome to remain unknown until an authoritative final record appears, so that absence of evidence is not converted into a result.
40. As a reader, I want a later reversal or amendment represented as a new decision in a later meeting, so that historical decisions are not rewritten.
41. As a reader, I want a dossier timeline to connect a continuing matter across meetings and communes, so that I can follow its history beyond one agenda item.
42. As a reader, I want an agenda item to link to multiple dossiers when the evidence supports that structure, so that complex matters are not forced into one artificial topic.
43. As a reader, I want a dossier to include agenda items from multiple communes when they concern the same continuing matter, so that cross-commune history is visible.
44. As a reader, I want merged or split dossiers to retain audit history, so that editorial restructuring does not erase prior associations.
45. As a reader following an old dossier URL, I want a redirect to the surviving dossier, so that existing links remain useful after a merge.
46. As a reader, I want to report an incorrect dossier link, so that a mistaken automated or editorial association can be reviewed.
47. As a reporter, I want my dossier-link report to create a private review item rather than immediately remove the link, so that public input cannot mutate publication state directly.
48. As an editor, I want a rejected dossier association recorded, so that the automated matcher does not recreate the same rejected link.

### Source acquisition and evidence preservation

49. As an editor, I want each commune polled through an explicit adapter, so that municipality-specific publication behavior remains understandable and testable.
50. As an editor, I want every authoritative index check preserved as an observation, so that disappearance, addition, and change can be reconstructed.
51. As an editor, I want an exact discovered source URL preserved with its parent index and meeting context, so that normalization does not erase discovery evidence.
52. As an editor, I want redirect chains and response metadata preserved, so that retrieval behavior remains auditable.
53. As an editor, I want unchanged responses recorded without creating duplicate source versions, so that the audit trail is complete but storage remains idempotent.
54. As an editor, I want each unique byte snapshot identified by SHA-256, so that a stable URL serving changed bytes creates a new immutable source version.
55. As an editor, I want source versions archived privately in content-addressed rustFS objects, so that exact evidence can be reproduced without exposing a public mirror.
56. As an editor, I want source records classified as agendas, supplements, addenda, explanatory notes, supporting dossiers, minutes, registers, voting records, decisions, livestreams, or recordings, so that processors apply the right semantics.
57. As an editor, I want Ixelles documents correlated through stable municipal meeting and item identifiers where available, so that agenda, project, minutes, and recording material can be connected safely.
58. As an editor, I want Uccle links scraped rather than synthesized from filenames, so that malformed, replacement, `bis`, base, and complementary files are all observed.
59. As an editor, I want Forest source history snapshotted aggressively and compared with final minutes, so that replaced pre-meeting files and in-session additions are retained.
60. As an editor, I want City of Brussels item-level supporting-document listings crawled in both available languages, so that rich dossier evidence is not reduced to the meeting-level agenda.
61. As an editor, I want delayed final records discovered after a meeting, so that a meeting page can move from unknown outcomes to documented decisions.
62. As an operator, I want active meeting windows checked frequently and older windows checked less frequently, so that updates arrive promptly without wasteful permanent polling.
63. As an operator, I want an authenticated `poll now` action, so that I can investigate a known municipal update without changing schedules.
64. As an operator, I want backfills to be explicit operations, so that historical archive work cannot unexpectedly consume production capacity.
65. As an editor, I want every public factual claim linked to claim-specific evidence, so that publication is traceable rather than merely plausible.
66. As an editor, I want evidence to identify its source, excerpt or location, retrieval time, and applicable period, so that the claim can be checked in context.
67. As an editor, I want contradictory and superseding evidence retained, so that current presentation does not erase the historical record.

### Extraction, normalization, and generation

68. As an operator, I want born-digital PDFs processed with native extraction first, so that expensive OCR is reserved for documents that need it.
69. As an operator, I want page-level extraction quality measured, so that a partly unreadable document cannot pass only because some pages contain text.
70. As an operator, I want failed native extraction routed through French-and-Dutch OCR, so that scanned bilingual municipal records can be recovered.
71. As an operator, I want OCR isolated at concurrency one with hard resource and time limits, so that document processing cannot starve the public application.
72. As an editor, I want every extraction and normalization attempt recorded as a versioned processing run, so that results can be reproduced after processor changes.
73. As an editor, I want extracted text, OCR text, normalized structures, and future transcripts stored as immutable derived artifacts, so that later processors do not overwrite earlier outputs.
74. As an editor, I want normalization to use commune-specific rules, so that incompatible source conventions are not hidden behind a false generic parser.
75. As an editor, I want parser ambiguity to create a review case, so that uncertain agenda identity or outcome is not guessed.
76. As an editor, I want automated dossier links to retain matching provenance and confidence, so that I can understand why a link exists.
77. As an editor, I want authoritative or high-confidence dossier matches linked directly, so that dependable continuity does not require routine manual work.
78. As an editor, I want medium-confidence matches to create a separate dossier and merge suggestion, so that uncertain continuity does not collapse distinct matters.
79. As an editor, I want generated French copy and its Dutch and English variants to retain processor and provenance metadata, so that the production path is auditable.
80. As an operator, I want automatic transcription disabled by default, so that the constrained host is not overloaded before representative bilingual benchmarks exist.

### Publication, revisions, and withdrawal

81. As an editor, I want a meeting page to have only `draft` and `published` publication statuses, so that the public lifecycle remains simple.
82. As an editor, I want a draft meeting page to publish automatically when complete French, Dutch, and English locale variants and claim-specific official evidence all pass, so that routine publication does not wait for personal approval.
83. As an editor, I want a failed publication gate to report exact missing variants, evidence, or provenance requirements, so that it creates actionable work rather than a generic failure.
84. As a reader, I want all three locale variants to become visible atomically, so that no language gets an incomplete or stale public page.
85. As an editor, I want ordinary post-publication factual edits to create dated revisions without introducing another publication status, so that correction history is explicit.
86. As a reader, I want factual corrections to display a dated correction note, so that material changes are transparent.
87. As an editor, I want typography and formatting changes to avoid a public correction note, so that revision history is not cluttered with non-factual changes.
88. As an editor, I want to move a published page back to `draft`, so that unsafe or materially flawed content can be hidden.
89. As a reader visiting a withdrawn page URL, I want a withdrawal notice instead of the hidden content or a missing page, so that the publication's action remains visible.
90. As an editor, I want revising a published page to preserve previous public revisions, so that publication history cannot be silently rewritten.

### Review workflow

91. As an editor, I want one review inbox for actionable domain ambiguity, so that acquisition, extraction, normalization, evidence, and public suggestions can be handled consistently.
92. As an editor, I want review cases separate from Oban job records, so that domain work survives transport retries and job pruning.
93. As an editor, I want each case to show its kind, commune, urgency, affected record, generation, and current disposition, so that I can triage efficiently.
94. As an editor, I want a source-versus-extracted-text detail view, so that I can identify extraction and OCR defects in context.
95. As an editor, I want the case to expose source locators, immutable source versions, hashes, HTTP history, processor logs, quality measurements, derived artifacts, and normalized content, so that review has a complete evidence chain.
96. As an editor, I want to retry a transient or corrected processing step, so that a new processing run can resolve the case without mutating history.
97. As an editor, I want to reclassify a source record, so that an incorrect document role can be corrected through an audited revision.
98. As an editor, I want to relink affected meetings, agenda items, dossiers, evidence, people, or legal entities, so that normalization mistakes can be repaired explicitly.
99. As an editor, I want to mark unsupported media or structure explicitly, so that the same deterministic failure does not retry forever.
100. As an editor, I want notes and dispositions retained on every case, so that later reviewers can reconstruct the decision.
101. As an editor, I want duplicate cases suppressed by affected record and processing generation, so that one failure does not flood the inbox.
102. As an operator, I want transient failures retried finitely with jitter and `Retry-After` support, so that temporary municipal failures recover without becoming infinite loops.
103. As an editor, I want deterministic corruption, authentication failure, invalid content, parser ambiguity, unsupported media, and repeated quality failure converted into review cases, so that retries stop when human judgment is required.

### Identity, company information, and relationship publication

104. As an editor, I want a legal entity created only around a CBE enterprise number, so that a name match never invents a company identity.
105. As an editor, I want establishment units and trading names attached to their legal entity, so that alternate names do not become duplicate companies.
106. As an editor, I want a person resolved only through an explicit identifier or exact name plus a corroborating fact, so that ambiguous people remain separate.
107. As an editor, I want textual mentions retained without asserting identity or involvement, so that extraction signals cannot become unsupported facts.
108. As an editor, I want typed, time-bounded roles and relationship claims, so that management, ownership, public mandate, contract, donation, declared interest, and office holding remain distinct.
109. As a reader, I want management never presented as ownership, so that corporate roles are not overstated.
110. As a reader, I want missing ownership information to produce no ownership claim, so that absence is not filled by inference.
111. As an editor, I want each publishable relationship claim to retain authoritative evidence, effective dates when known, and a verification status before automatic publication, so that evidentiary responsibility remains explicit without making routine publication wait for personal approval.
112. As an editor, I want rejected or superseded claims retained historically, so that new evidence changes current presentation without erasing prior review.
113. As an editor, I want company enrichment to run asynchronously, so that unresolved entities do not block neutral meeting publication.
114. As a reader, I want verified enrichment to update relevant public coverage through a dated revision later, so that meeting reporting can improve after initial publication.
115. As a privacy-conscious reader, I want person profiles limited to legal name, sourced professional roles, public mandates, relevant council mentions, and a dated timeline, so that irrelevant private data is not republished.
116. As a person represented in evidence, I want private addresses, signatures, contact details, identity numbers, and family information excluded, so that public-interest reporting remains proportionate.
117. As Rico, I want public relationship pages to fail closed unless every displayed fact passes the automated identity, authoritative-evidence, neutral-wording, and privacy rules, so that implementation readiness is not mistaken for publishable evidence.
118. As a neutral-meeting reader, I want unresolved identity enrichment to remain independent of meeting, agenda, decision, evidence, and dossier publication, so that optional enrichment never blocks the core civic publication.
119. As an editor, I want relationship claims based on model inference, name similarity, shared surnames, shared addresses, or third-party graphs to remain internal unreviewed leads, so that they are never published as facts.
120. As a reader, I want relationship wording to state sourced neutral facts without automatically alleging influence, wrongdoing, or conflict of interest, so that the publication does not exceed its evidence.
121. As an editor, I want CBE Open Data to provide the structured legal-entity spine under its accepted terms, so that systematic ingestion does not misuse CBE Public Search.
122. As an editor, I want Belgian Official Gazette acts and official decisions to provide dated claim evidence, so that changes in officers and roles have authoritative support.
123. As an editor, I want NBB accounts, procurement records, mandate publications, and other official records used only for the claims they actually establish, so that a tender is not misreported as an award and an account is not treated as a universal ownership register.
124. As an editor, I want UBO data excluded from the product unless legal access, storage, and republication rights are explicitly established, so that restricted information does not become an accidental MVP dependency.

### Public suggestions and corrections

125. As a reader, I want to suggest missing ownership information in open-ended text without an account, so that I can provide a useful private lead with low friction.
126. As a reader, I want to suggest a correction from a company or person page without an account, so that factual errors can enter review.
127. As a submitter, I want contact information to be optional and private, so that I can choose whether the editor can follow up without publishing my identity.
128. As an operator, I want suggestion forms protected by basic rate limits and a honeypot, so that obvious automated abuse is reduced without creating accounts.
129. As an editor, I want suggestions to remain private until I approve or reject them, so that submissions cannot create public claims directly.
130. As an editor, I want an approved suggestion to create evidence-backed domain revisions rather than directly editing public text, so that the ordinary evidence and publication rules still apply.
131. As an editor, I want rejected suggestions retained privately, so that repeated unsupported submissions can be recognized.
132. As an editor, I want identity merge and split decisions audited and retired duplicate profile URLs redirected, so that corrections preserve continuity.

### Operations and deployment

133. As an operator, I want the application deployed through Coolify behind its managed ingress, so that it follows the existing estate contract.
134. As an operator, I want brussels.wtf to use a dedicated logical PostgreSQL database and least-privilege role, so that its structured state is isolated from other applications.
135. As an operator, I want brussels.wtf to use a dedicated private rustFS bucket and bucket-scoped credentials, so that source evidence is isolated within the shared object service.
136. As an operator, I want storage configuration injected through Coolify secrets and variables, so that credentials do not enter source control, logs, issues, or public documentation.
137. As an operator, I want releases to run application migrations but never create cluster-level databases, roles, buckets, or service credentials, so that provisioning remains an explicit estate operation.
138. As an operator, I want startup or release validation to fail when the private bucket is absent or inaccessible, so that evidence is never silently lost.
139. As an operator, I want no local-disk fallback for the source archive, so that production behavior remains consistent with the immutable archive contract.
140. As an operator, I want PostgreSQL to be the only queue and coordination dependency, so that the MVP does not introduce unnecessary infrastructure.
141. As an operator, I want web, lightweight worker, OCR, and future transcription roles to have explicit queue boundaries, so that heavy processors can be constrained independently.
142. As an operator, I want application health checks to distinguish web readiness, database migration state, and archive accessibility, so that a release cannot appear healthy while evidence storage is unusable.
143. As an operator, I want secrets and private object keys redacted from logs and public error output, so that least-privilege storage is not undermined operationally.
144. As the estate owner, I want backup, off-host copy, retention, and restore testing owned outside the brussels.wtf application and repository, so that this MVP does not invent or claim an application backup system.

## Implementation Decisions

### 1. Product boundary and delivery sequence

- The neutral municipal publication is the launchable MVP core: commune discovery, source preservation, extraction, normalization, meeting pages, agenda-item coverage, proposals, decisions, evidence citations, dossier timelines, multilingual publication, corrections, withdrawal, and review cases.
- Identity and relationship foundations share the domain model. [Add private CBE entity resolution and enrichment](https://github.com/RicoTrevisan/brussels-wtf/issues/29) retains private candidate facts only; [Enable evidence-gated profiles, relationships, and suggestions](https://github.com/RicoTrevisan/brussels-wtf/issues/30) must add the trusted verifier, one-way audit transition, current-fact projection, and public-route seam before company/person pages expose anything. Unresolved enrichment and private suggestions do not block neutral meeting or dossier implementation.
- Implementation should proceed through tracer bullets that prove one representative meeting end to end before expanding adapter coverage. Ixelles is the preferred first acquisition tracer because its meeting identifiers are strongest. Uccle should prove explicit pre-meeting versions, Forest should prove overwritten/complementary sources and in-session additions, and the City of Brussels should prove item-level supporting-document crawling.
- Search, audience growth, and broader enrichment must not expand the first complete publication seam.

### 2. Application architecture

- Use one Phoenix/Ash codebase with Dstar integration, Tailwind, and DaisyUI. Tidewave is enabled only in development.
- Ash resources and actions own domain invariants, lifecycle transitions, evidence relationships, review dispositions, revision creation, and publication-gate evaluation.
- Plain Oban workers own external I/O orchestration and invoke named Ash actions with explicit inputs. Oban job state is transport state and never serves as the review inbox, audit history, or publication state.
- PostgreSQL is the system of record for structured state, idempotency constraints, Oban jobs, and due-work scheduling.
- rustFS is the private immutable object store for raw source versions and large derived artifacts. Structured metadata and object hashes live in PostgreSQL.
- External systems and processors sit behind named adapter boundaries: commune discovery, HTTP retrieval, object storage, PDF metadata/text extraction, OCR, content generation/translation, and optional future transcription. Domain actions receive explicit results rather than invoking external programs invisibly.

### 3. Canonical resource model and invariants

- Model communes for exactly Ixelles, Uccle, Forest, and the City of Brussels in the MVP.
- Model council meetings with commune, authoritative identifiers where available, scheduled time, meeting context, discovery state, and one meeting page.
- Model source records as authoritative published items with document role, original language, publisher origin, publication time when known, and links to a council meeting or agenda item as supported by evidence.
- Model source locators independently from source records. A source locator preserves the exact URL, parent index, discovery context, observed labels, and redirects; it is not a version identity.
- Model poll runs and retrieval observations so every due check records unchanged responses, redirects, metadata, success, failure, or disappearance. A successful observation links to the source version served at that time.
- Model source versions as immutable byte snapshots with media type, byte size, SHA-256 hash, private object key, first retrieval time, and source record. The authoritative uniqueness is the source record plus raw hash.
- Model processing runs by source version, processor name, processor version, configuration hash, status, timing, logs or diagnostics, quality measurements, and failure classification.
- Model derived artifacts as immutable processor outputs with input hash, output hash, output kind, processor provenance, and private object key or structured payload as appropriate.
- Model agendas as versioned lists belonging to exactly one council meeting. Base, supplement, addendum, corrected, and final source records remain distinct even when they contribute to one normalized agenda history.
- Model agenda items as meeting-specific occurrences. Preserve authoritative item identifiers, sequence or display number, source wording, item-level evidence, and explicit continuity across agenda versions.
- Model proposals separately from decisions. A proposal records the action described before the council acts. A decision records only an explicitly sourced final disposition and supporting details. No final evidence means unknown outcome.
- Model voting details only when authoritative final evidence supplies them; retain totals and named votes only to the extent the source explicitly provides them and legal/privacy policy permits their presentation.
- Model dossiers as continuing real-world matters with stable public identities and timeline pages. Model dossier links as many-to-many links to agenda items with matching method, confidence, processor provenance, status, and editorial disposition.
- Model revisions for meeting pages, coverage items, and dossiers. Factual revisions bind the synchronized locale variants and correction metadata; locale-specific typography revisions remain distinguishable.
- Model content provenance as composable truths rather than one exclusive state. `AI-generated`, `machine-translated`, and `human-reviewed` are recorded independently.
- Model evidence as claim-specific support or contradiction with source, source version where appropriate, excerpt or location, retrieval time, applicable period, and public citation origin.
- Model mentions separately from legal entities, people, roles, or relationship claims. A mention may remain unresolved indefinitely.
- Model legal entities around CBE enterprise numbers. Alternate names and establishment units attach to the same legal entity.
- Model people with evidence for identity resolution. Ambiguous records remain separate and merge/split operations retain history.
- Model roles and relationship claims as typed and time-bounded. Verification status is independent of whether a containing page is publicly available.
- Model suggestions, correction suggestions, link correction reports, reviewer notes, and review cases as private records with audited dispositions.

### 4. Idempotency and immutable history

- PostgreSQL unique constraints are authoritative. Oban uniqueness may suppress duplicate work but cannot establish domain identity.
- Raw bytes are identified by SHA-256. URL, filename, visible title, ETag, and Last-Modified are observations only and can never identify a source version.
- Enforce the accepted uniqueness contracts for source versions, retrieval observations, processing runs, derived artifacts, optional future transcriptions, and review cases.
- Retrying a processor with the same source, processor version, and configuration resolves to the existing processing identity. A changed processor or configuration creates a new processing run and generation.
- Corrections, review actions, merges, splits, relinks, and later decisions append domain history. They do not rewrite source versions, prior decisions, prior relationship roles, or prior public revisions.
- Retired dossier and duplicate profile identities retain redirect mappings and audit history.

### 5. Commune discovery adapters

- Define one common discovery result contract while keeping four explicit implementations. The contract yields index observations, meeting context, exact source locators, observed labels, language, candidate source role, and authoritative identifiers without forcing municipality-specific parsing into a generic scraper.
- The Ixelles adapter correlates agenda, project material, minutes, and direct recording links through stable numeric meeting identifiers and item identifiers when present. It still hashes every retrieval because a generic agenda URL may be replaced by a complementary version.
- The Uccle adapter scrapes every discovered link and classifies base/complementary agendas, explanatory notes, motions, questions, interpellations, and registers. It treats replacement markers and malformed filenames as observations, not generated address conventions.
- The Forest adapter keys meetings primarily by date and index context, archives every observed revision, recognizes complementary documents, preserves separately linked motions/interpellations, and compares final minutes with pre-meeting agendas for additions made in session.
- The City of Brussels adapter crawls the year index, base and supplement item-document listings, and the child attachments for each item. It preserves French and Dutch supporting files separately and uses meeting date, authoritative item number, and internal dossier identifier where available.
- Recording discovery remains source-specific and confidence-aware. A direct authoritative meeting link can become a source record. Heuristic date/title matching remains an internal lead until confirmed and is not required for neutral written publication.

### 6. Polling, retrieval, and retry policy

- Stagger commune index polls every six hours.
- Re-fetch locators in the window from 30 days before through 30 days after a meeting every six hours.
- Check daily until 180 days after a meeting, or until final records have remained unchanged for 30 days.
- Poll the previous-year index daily for delayed records. Historical backfill is an explicit authenticated operation rather than continuous work.
- Store `next_fetch_at` on locator state and select due work from PostgreSQL. Do not create dynamic cron entries per source URL.
- Provide an authenticated `poll now` action scoped by commune, meeting, locator, or index as appropriate, and record who requested it.
- Use finite acquisition retries with jitter at approximately 30 seconds, 2 minutes, 10 minutes, 1 hour, 6 hours, and 24 hours. Respect `Retry-After`.
- Retry transient network failures, HTTP 408, 425, 429, 5xx, and newly discovered 404 responses. Record each attempt as a retrieval observation.
- Convert deterministic corruption, authentication failures, invalid content, unsupported media, parser ambiguity, and repeated quality-gate failures into review cases rather than indefinite retry loops.
- Preserve exact URLs and redirect chains. Any normalized URL used for operational grouping must not replace the discovered locator.

### 7. Private object archive

- Write new raw bytes to content-addressed object keys derived from the SHA-256 hash. Write-once behavior and hash verification are required before a source version becomes available to processors.
- Store extracted text, OCR output, normalized snapshots when externalized, and future transcript artifacts under immutable content-addressed keys distinct from raw objects.
- Private object keys are internal evidence metadata. Public pages link to authoritative publisher origins and may expose checksum and retrieval time, but never produce unauthenticated rustFS links.
- The storage adapter must support the rustFS S3-compatible endpoint, path/addressing behavior, upload, read-after-write verification, metadata retrieval, and bounded representative large uploads. ReqS3 is the initial client candidate only after those integration tests pass; ExAws/ExAws.S3 is the accepted fallback. No custom S3 client will be invented.
- Production must fail release validation or startup readiness when bucket configuration is absent, credentials lack required access, or a write/read/delete validation against a designated validation prefix fails. There is no local-disk fallback.

### 8. Extraction and OCR

- Run Poppler metadata and text extraction first for PDFs. Capture tool version, command outcome, page count, language signals where available, and page-level text quality measurements.
- Acceptance is based on explicit page-level measurements rather than only total character count. Threshold values must be calibrated with representative fixtures from all four communes before being promoted to production configuration.
- Route only pages or documents that fail native quality to OCRmyPDF/Tesseract using French and Dutch language data. Preserve raw source bytes and store OCR output as a derived artifact.
- Run OCR in an isolated application role or service from the same release image, at queue concurrency one, with explicit CPU, memory, and wall-time limits. Failure due to a hard limit creates a classified processing failure and, after bounded retry where appropriate, a review case.
- Transcription queue and domain contracts may exist, but automatic transcription remains disabled. It can be enabled only after a separately accepted benchmark using representative bilingual recordings, a pinned binary/model, and safe host throughput.

### 9. Normalization and domain transitions

- Each commune normalizer consumes immutable source versions or accepted derived text plus explicit processing context. It returns candidate normalized structures and evidence locations; Ash actions validate and commit domain transitions.
- Normalize proposed states only from agendas or supporting material. Normalize final dispositions only from minutes, registers, adopted decisions, or another authoritative final municipal record.
- Supplements update an agenda item only when an authoritative item identifier or equivalent explicit evidence proves continuity. New matters create new agenda items.
- Detect items present only in final records and add them as meeting-specific agenda items with their final evidence, preserving that no pre-meeting version was observed.
- A later meeting that amends or reverses an earlier decision creates a new agenda item and decision linked through a dossier. It does not mutate the earlier decision.
- Dossier matching uses authoritative identifiers first, then a documented high-confidence matcher. High-confidence matches can create a dossier link directly. Medium-confidence matches create a separate dossier and private merge suggestion. Lower confidence remains an internal signal.
- Every automated dossier link records matcher name/version, features or authoritative identifier used, confidence, source agenda items, and processing generation.
- An editor can merge, split, or relink dossiers through audited actions. Rejected links create a durable matcher exclusion with enough context to prevent the same association from recurring.

### 10. Content generation, translation, and provenance

- French is the canonical editorial representation for MVP public copy. Source-language excerpts remain in their original language and are cited independently.
- Content generation and translation are versioned processors. Each run records provider category, model or processor identity, version, configuration hash, inputs, outputs, timing, cost/usage where available, and failure details without logging secrets.
- Provider and model choice, thresholds, budgets, and fallback behavior remain configuration decisions to be settled by a tracer-bullet benchmark; domain contracts must not depend on one provider.
- Generated claims may only draw from normalized state and attached evidence. The publication gate validates claim-specific evidence independently of the model output.
- Generate all three locale variants before publication. There is no public mixed-language fallback and no partial locale publication.
- `AI-generated` applies when model generation produced the text, `machine-translated` applies when a machine produced that locale from another locale, and `human-reviewed` applies only after an authenticated review action. Labels compose.
- Factual corrections originate as one synchronized revision intent and must produce valid FR/NL/EN variants before becoming public. Typography-only corrections may be locale-specific and cannot alter normalized factual claims.

### 11. Publication gate and public revision lifecycle

- A meeting page has exactly `draft` and `published` status. Coverage items inherit the page's public visibility and remain individually addressable by anchors.
- The publication gate checks complete FR/NL/EN locale variants, claim-specific official evidence, proposal-versus-decision semantics, required content provenance, valid citations, and absence of blocking review cases for the content generation being published.
- Rico may review or edit content, but approval is not a general publication prerequisite. `human-reviewed` is provenance, not publication status.
- Publishing transitions all locale variants and coverage items atomically in one database transaction after gate evaluation. External side effects triggered by publication must be idempotent and cannot expose a partial page.
- A final municipal record updates the same meeting page through a new dated revision. Existing proposal coverage remains historically distinguishable; it is not rewritten to look like a decision.
- Factual edits create a dated correction note and synchronized locale revision. Typography/formatting changes can be silent and locale-specific.
- Moving a published page back to `draft` hides its content while preserving public URLs and rendering a withdrawal notice. Republishing creates a new public revision and does not erase the withdrawal interval.
- Publication and revision events retain actor or processor, gate result, timestamp, evidence set, locale set, and provenance set.

### 12. Public interface

- Reproduce the accepted timeline behavior from the prototype as production behavior rather than copying static prototype implementation.
- The homepage contains distinct `Coming up` and `What they decided` timelines, ordered predictably by meeting/revision dates and filtered to the selected communes.
- First visit selects all four communes. Commune selection persists locally in the browser and requires no account. Server-rendered output must remain useful when no persisted preference is available.
- Timeline entries display commune, meeting date, agenda-item number, factual summary, proposal/decision/unknown status, applicable provenance labels, citations, and available dossier/company/person links.
- Entries link to stable agenda-item anchors within a meeting page. There is no separate article route for a coverage item.
- Meeting pages display meeting context, dated page revision, source citations, grouped coverage items in authoritative order, clear proposal/decision distinction, and dossier links.
- Dossier pages present a dated cross-meeting timeline and expose dossier-link correction reporting. Retired dossier routes redirect to the surviving dossier.
- Use one stable path per resource. An optional valid BCP 47 `lang` query parameter selects locale. Resolution precedence is explicit `lang`, persisted reader choice, browser `Accept-Language` on first visit, then English.
- Canonical and alternate-language metadata must preserve one resource identity and avoid locale-prefixed duplicate paths.
- Public pages must be responsive, keyboard navigable, semantically structured, and usable without client-side JavaScript for core reading and citations. Local filter/language persistence may enhance the server-rendered baseline.

### 13. Review interface and audited actions

- Protect the review interface and all operational actions behind authentication and authorization for Rico. The exact authentication mechanism is an unresolved implementation prerequisite; no review route or operational action may ship publicly while it is unresolved.
- The review inbox is queryable by case kind, commune, status, generation, and age. It distinguishes actionable domain cases from current worker execution state.
- Case details show authoritative origin, locator history, source versions, hashes, relevant private artifact previews, extracted/OCR text, processor logs, quality metrics, affected normalized records, related evidence, reviewer notes, and prior actions.
- Allowed actions are explicit domain commands: retry, reclassify, relink, correct, mark unsupported, confirm/remove dossier link, merge/split dossier, approve/reject suggestion, merge/split identity, supersede claim, and withdraw/republish meeting page as applicable.
- Actions create new processing runs, derived artifacts, domain revisions, exclusions, or dispositions. They never mutate raw source versions.
- Review-case uniqueness is based on failure kind, affected record, and processing generation. A later generation can create a new case; duplicate reports in one generation converge.
- Private artifact access uses authenticated, short-lived application mediation or equivalent protected access. Private object credentials and permanent object URLs are never exposed to the browser.

### 14. Identity and relationship evidence

- Use CBE Open Data, under accepted reuse terms, as the systematic legal-entity source. CBE Public Search is for targeted human verification, not bulk ingestion.
- Preserve CBE enterprise number, source release/update identity, and relevant registered facts. Legal-entity creation requires an enterprise number.
- Use Belgian Official Gazette acts and official municipal decisions as dated evidence for appointments, resignations, and other explicit facts. NBB accounts, procurement/award records, Court of Audit mandate publications, and other official sources may support only the facts they explicitly establish.
- Do not depend on bulk UBO access. UBO evidence remains disabled unless lawful access eligibility, terms, storage, and republication rights are explicitly established.
- Person identity requires an explicit identifier or exact name plus at least one corroborating fact such as municipality, dated mandate, organization, or role. Ambiguous candidate identities remain separate.
- Store typed facts and derive broader intersections only from verified underlying claims. Management never implies ownership; a textual mention is not a relationship; a tender notice is not an award.
- A relationship claim is eligible for automatic public presentation only when it has direct authoritative evidence, resolved identities, precise neutral wording, and applicable dates. Human review is optional provenance, not a publication prerequisite.
- Public profile fields are limited to legal name, sourced roles, public mandates, relevant council mentions, and dated timelines. Private addresses, signatures, contacts, identity numbers, and family data are excluded from public output and generation inputs unless strictly necessary for private identity disambiguation.
- Relationship routes, navigation, feeds, and indexing include only verified public projections. Internal leads remain private and cannot satisfy a public evidence gate.
- Editorial charter, journalistic-purpose basis, source licensing, correction process, relationship wording, retention/removal policy, and UBO handling remain explicit product policies and may tighten the automated rules without introducing a blanket approval state.

### 15. Public submissions

- Dossier-link correction reports are part of the neutral MVP and create private review items without mutating the link.
- Ownership and profile correction suggestion forms are implemented only with the corresponding public profile surface.
- Public forms accept open-ended text without accounts, optional private contact information, a honeypot field, and basic rate limiting keyed using privacy-conscious operational data.
- Submission payloads, contact details, anti-abuse data, reviewer decisions, and retention status remain private. Public publication occurs only through an approved evidence-backed domain action and the applicable publication gate.
- Approval does not treat user text as authoritative evidence. It either attaches authoritative evidence supplied or discovered during review, or leaves the claim unpublished.
- Rejections and identity/dossier merge or split dispositions remain in non-sensitive audit history to prevent repeated unsupported associations.
- Suggestion contact is retained for at most 90 days and at most 30 days after moderation. Keyed anti-abuse values are retained for at most 48 hours. Submission bodies are retained for 365 days. Keyed repeat-suppression fingerprints and reviewer notes have explicit deadlines and are purged by bounded scheduled maintenance; the non-sensitive moderation disposition remains append-only.

### 16. Queues and process roles

- Use named queues for `poll`, `fetch`, `extract`, `ocr`, `normalize`, `publish`, and disabled-by-default `transcription` work.
- The web release and lightweight workers may share one Coolify application initially. OCR runs in an isolated process role or service from the same release image with concurrency one and hard limits.
- Queue concurrency values other than OCR are deployment configuration calibrated against the host. They must preserve web responsiveness and database/rustFS health.
- Use cron only to enqueue commune polls and fixed maintenance work. Locator due times remain data in PostgreSQL.
- Workers are safe under at-least-once execution because domain writes use unique constraints and named idempotent Ash actions.

### 17. Production storage and release contract

- Reuse the existing Coolify-managed PostgreSQL and rustFS services. Do not deploy PostgreSQL, rustFS, a queue broker, or replacement object storage from this application.
- Before first release, an operator provisions a dedicated logical database, least-privilege application role, dedicated private bucket, and bucket-scoped credentials outside the application.
- PostgreSQL is configured through `DATABASE_URL`. rustFS is configured through the accepted source-archive endpoint, bucket, region, access-key, and secret-key variables supplied by Coolify.
- Application releases run migrations against the dedicated database and validate source-archive access. They do not create cluster roles, databases, buckets, policies, or credentials.
- Secrets, private endpoints, private object keys, and credentials remain outside source control, issue comments, public documentation, client output, and ordinary logs.
- Readiness fails when database migrations are pending or archive validation fails. Liveness must not perform destructive or expensive storage checks.
- Coolify owns service connectivity, environment injection, process rollout, and ingress. Operator-controlled service mutation, restart, or redeploy remains outside application behavior.
- Backups, off-host copies, retention schedules, and restore testing are estate responsibilities outside this repository and are not an application launch gate. The application neither asserts that a backup system exists nor implements one.

### 18. Observability and operational safety

- Emit structured logs and metrics around poll duration, retrieval status, changed hashes, bytes archived, extraction quality, OCR routing, processor duration, retries, review-case creation, publication-gate failures, and queue age.
- Correlate logs by poll run, retrieval observation, source version, processing run, review case, and publication revision without logging secrets or private suggestion content.
- Surface actionable health indicators for stale commune polling, repeated acquisition failures, OCR backlog, inaccessible rustFS, delayed final-record discovery, and publication drafts blocked by gates.
- Processor failures expose safe summaries to operators and detailed private diagnostics in review. Public readers receive no internal stack traces, private object paths, or submission data.
- Resource limits and queue concurrency are configuration, not hidden defaults. Production transcription remains visibly disabled.

## Testing Decisions

### Testing philosophy and principal seam

- Tests assert externally observable domain and user behavior, not private function calls, process layout, SQL implementation details, or HTML class names.
- The highest meaningful test seam is the principal acceptance seam and should carry most confidence: **a representative municipal source fixture enters through a commune adapter, produces retrieval observations and an immutable source version, proceeds through extraction and normalization into meeting/agenda/dossier/claim state, and ends as either a rendered multilingual public page or an actionable review case**.
- The principal seam must exercise real Ash actions, PostgreSQL constraints, Oban job execution, route rendering, publication gates, locale resolution, citations, and revision behavior. External HTTP, rustFS, model services, and expensive binaries may use faithful controllable adapters at this seam, while their contracts are proven separately against the real systems.
- Prefer a small matrix of end-to-end municipal scenarios over unit tests for every worker or resource. Add focused lower seams only for source-specific parsing, external binaries/adapters, deterministic pure policies with large edge-case matrices, or failure modes that cannot be exercised economically at the principal seam.
- Test fixtures are versioned evidence scenarios, not arbitrary mocked records. Each fixture states its authoritative index, exact locators, response sequence, bytes/hashes, document role, expected normalized facts, and expected public or review outcome.

### Principal acceptance scenarios

1. **Ixelles proposal to final decision:** discover an agenda and project source under a stable meeting identifier, archive bytes, normalize agenda items and proposals, publish complete FR/NL/EN upcoming coverage, later discover minutes at the same meeting identifier, normalize the sourced final disposition and vote, and render a new dated meeting-page revision in `What they decided` without rewriting the proposal history.
2. **Same locator, changed bytes:** retrieve one agenda URL twice with different bytes, preserve both retrieval observations and both source versions, keep both hashes and exact origins, process the later version, and expose appropriate source-version metadata without overwriting the first.
3. **Unchanged retrieval:** receive an unchanged response or identical bytes, record another retrieval observation, create no duplicate source version or processing run, and leave rendered content unchanged.
4. **Uccle base and complementary versions:** discover malformed and replacement-style filenames from the index, preserve all exact locators, classify base/complementary agendas and explanatory notes, update authoritatively continuous items, add genuinely new matters, and render the correct latest proposal state with prior evidence retained.
5. **Forest complementary replacement and in-session addition:** archive a complementary pre-meeting source, later parse minutes containing an item absent from the agenda, create a separate agenda item with no invented proposal, attach final evidence, and render the decision.
6. **City item-level bilingual evidence:** crawl a meeting index and item-document listing, retrieve separate French and Dutch supporting files, connect them to the authoritative agenda item and internal dossier identifier, and render citations without synthesizing filenames.
7. **Native extraction success:** accept page-level native text quality, create processing runs and derived text artifact, skip OCR, normalize, and publish.
8. **OCR fallback success:** fail native quality on one or more pages, route through bounded French/Dutch OCR, retain both native and OCR artifacts with provenance, normalize from the accepted artifact, and publish if every gate passes.
9. **Deterministic extraction failure:** encounter corrupt or unsupported content, exhaust only applicable bounded behavior, create one review case for the processing generation, and render no unsupported public claim.
10. **Normalization ambiguity:** process a supplement whose item continuity is not authoritatively established, preserve candidate state privately, create a review case or separate matter as dictated by confidence, and avoid silently changing the published agenda item.
11. **Dossier confidence behavior:** directly link authoritative/high-confidence agenda items with provenance, create a separate dossier and merge suggestion for medium confidence, and keep lower-confidence signals private.
12. **Incorrect dossier-link report:** submit a public report, retain the public link until review, remove it through an audited editor action, preserve the disposition, and verify that rerunning the same matcher does not recreate it.
13. **Atomic multilingual gate:** withhold a draft when one locale is absent, publish all variants in one transition after it appears, verify no mixed-language fallback, and render provenance labels accurately.
14. **Missing evidence gate:** withhold a claim whose locale variants exist but official evidence is absent or inapplicable, expose an actionable gate failure or review case, and publish once valid claim-specific evidence is attached.
15. **Proposal/decision distinction:** ensure an agenda can only produce a proposal, an authoritative final record can produce a decision, and absence of the final record renders unknown outcome rather than approval.
16. **Factual correction:** create a synchronized FR/NL/EN correction revision with a dated note, preserve the prior revision, and show the corrected version at the stable URL.
17. **Typography-only correction:** change one locale's typography without changing normalized facts or creating a public factual correction note.
18. **Withdrawal and republication:** move a published meeting page to `draft`, render a withdrawal notice at all stable language variants and anchors, then republish a later revision without erasing the withdrawal history.
19. **Locale resolution:** verify explicit valid query parameter, persisted selection, first-visit `Accept-Language`, English fallback, invalid input handling, and one stable path per resource.
20. **Review action immutability:** retry, reclassify, relink, or correct a case; confirm that a new run/artifact/revision exists and raw source bytes, original source version, and previous normalized revision are unchanged.
21. **Asynchronous enrichment:** publish a neutral meeting with an unresolved mention, later attach a CBE-resolved legal entity and verified facts, and update eligible content through a dated revision without having blocked initial publication.
22. **Automated relationship publication:** verify that neutral meeting and dossier pages render independently, while relationship routes, navigation, feeds, and indexing expose only resolved, directly evidenced, neutrally worded, privacy-safe facts without a human approval prerequisite.
23. **Relationship evidence safety:** verify that name similarity, shared address, management role, missing ownership, a tender notice, and model inference do not produce ownership, award, conflict, or vague connection claims.
24. **Suggestion privacy and moderation:** submit anonymous open text with optional contact from an eligible public profile, exercise honeypot and rate limiting, verify private storage, and ensure approval still requires independently verified evidence and never publishes user text.
25. **Finite retry behavior:** exercise transient HTTP statuses and `Retry-After`, verify bounded observations and delays, then create one review case after the accepted terminal condition.
26. **Archive unavailability:** make rustFS inaccessible and verify release/readiness failure, no local fallback, no source-version commitment without verified object storage, and safe diagnostics.
27. **At-least-once execution:** run the same jobs concurrently or repeatedly and verify authoritative unique constraints prevent duplicate source versions, runs, artifacts, cases, and public revisions.

### Focused lower seams

- **Commune adapter contract tests:** parse captured authoritative HTML/index and document-listing fixtures for each commune, including malformed names, encoding quirks, duplicate labels, missing versions, and item-level attachments. Assert discovered locators and context, not parser internals.
- **HTTP retrieval adapter tests:** use a local controllable server to exercise redirects, conditional responses, identical bytes under changed headers, changed bytes under stable URLs, timeouts, `Retry-After`, transient statuses, disappearance, and bounded content size.
- **rustFS integration tests:** against a dedicated non-production test bucket, prove endpoint/addressing compatibility, scoped credentials, content-addressed upload, read-after-write hash verification, metadata, representative large upload, inaccessible-bucket failure, and private access. Run the same contract against ReqS3 before adoption; run it against ExAws/ExAws.S3 if fallback is needed.
- **Poppler/OCR executable contract tests:** in the production image, process a small representative corpus of born-digital, partially scanned, bilingual, rotated, malformed, and oversized PDFs. Assert page-level quality decisions, artifact hashes, tool provenance, resource/time limits, and classification of failures.
- **Publication-policy property tests:** cover combinations of locale completeness, claim evidence, proposal/decision source types, provenance labels, blocking cases, and legal-gate state. Assert allowed transitions and precise gate failures.
- **Dossier matcher tests:** use labeled positive, medium-confidence, negative, and previously rejected associations. Assert provenance, thresholds, separate-dossier behavior, and durable exclusions rather than the matcher's private scoring implementation.
- **Identity and relationship policy tests:** use explicit stable identifiers, corroborated/ambiguous names, dated roles, contradictory evidence, management-versus-ownership, tender-versus-award, and forbidden private fields. Assert public claim eligibility and redaction.
- **Rendering/accessibility tests:** assert headings, landmarks, links, anchor targets, status text, citations, language metadata, keyboard access, responsive behavior, and useful no-JavaScript reading. Avoid snapshots dominated by cosmetic markup.
- **Authorization tests:** assert anonymous users cannot access review data, private artifact mediation, operational actions, suggestion contacts, or unpublished revisions; assert the authorized editor can perform only explicit audited actions.
- **Release validation tests:** exercise missing database/archive variables, inaccessible bucket, pending migration, secret redaction, and successful validation against dedicated test namespaces.

### Test data and prior art

- The repository currently contains planning documents and a throwaway UI prototype rather than production test prior art. The accepted ADR scenarios and the prototype's validated timeline/review behaviors are the current behavioral references.
- Captured municipal fixtures must contain no invented facts presented as authoritative. If real source files are retained in test storage or distribution, their licensing and repository suitability must be reviewed; otherwise use minimal legally safe fixture extracts whose expected hashes and semantics are recorded.
- Model generation tests use deterministic recorded processor outputs at the principal seam. A separate opt-in provider contract suite validates request/response normalization, errors, usage metadata, and fallback behavior without making ordinary CI depend on paid or nondeterministic calls.
- Time-dependent polling and revision tests use a controlled clock. Hashes are calculated from fixture bytes. Concurrency/idempotency tests use the same database constraints as production.
- The release image, not a developer workstation, is the authority for Poppler, OCRmyPDF, Tesseract language data, and optional future transcription executable tests.

### Verification gates for implementation completion

- Every commune has at least one principal-seam fixture reaching either a valid multilingual public page or the intended review case.
- At least one fixture proves proposal-to-final-decision revision on the same meeting page.
- At least one fixture proves changed bytes at a stable locator and immutable history.
- At least one fixture proves OCR fallback under the production image and enforced concurrency/resource policy.
- rustFS compatibility is proven against a dedicated test bucket before selecting the S3 client.
- Public pages pass locale, citation, status-separation, accessibility, anchor, correction, and withdrawal acceptance scenarios.
- Neutral publication passes independently of unresolved relationship enrichment.
- No completion claim may rely only on unit tests or mocked resource calls when the higher principal seam can exercise the behavior.

## Out of Scope

- Municipalities other than Ixelles, Uccle, Forest, and the City of Brussels.
- Continuous historical backfill of every available archive; backfills are explicit later operations.
- Automatic transcription of every livestream or recording. Transcription remains disabled until a representative bilingual capacity benchmark is separately accepted.
- Depending on recordings for the authoritative final outcome when minutes, registers, decisions, or another final municipal record are required.
- Search, subscriptions, newsletters, alerts, RSS/Atom feeds, push notifications, maps, cross-commune comparison tools, company watchlists, and audience-growth workflows.
- Reader accounts, cross-device personalization, saved searches, comments, reactions, or community discussion.
- A separate article route for each coverage item; agenda items remain anchored within meeting pages.
- Municipal administration dashboards or workflows for commune staff.
- A generic one-size-fits-all municipal scraper, generic PDF parser framework, microservice architecture, Broadway, RabbitMQ, Kafka, Temporal, Oban Pro workflows, or dynamic cron per URL.
- AshOban as the initial external-I/O pipeline abstraction.
- OCR on every PDF, LLM/vision OCR as authoritative extraction, or unbounded CPU/memory processing.
- Inferring final outcomes from agendas, silence, livestreams, disappearance, or model output.
- Publishing accusations, inferred influence, wrongdoing, conflicts of interest, vague company/councillor connections, or relationships based only on a mention, name similarity, shared surname/address, or model inference.
- Treating management as ownership, a tender as an award, annual accounts as a universal ownership register, or missing data as a positive claim.
- Bulk UBO ingestion or any UBO-dependent feature before access and republication rights are explicitly resolved.
- Launching company/person relationship pages that expose unresolved, inferred, unsupported, or privacy-excluded facts.
- A complete right-of-reply workflow. The MVP includes factual correction and dossier-link reporting; any additional legal process is a later policy decision.
- Buying, configuring, or transferring the `brussels.wtf` domain.
- Provisioning or deploying PostgreSQL or rustFS from the application.
- Cluster-level database roles, databases, buckets, storage policies, and credentials created by application releases.
- An application-owned backup stack, scheduled backups, off-host copies, backup retention, restore testing, or claims about whether an estate-wide backup system exists.
- Replacing Coolify, Traefik, shared PostgreSQL, or shared rustFS.
- Copying the throwaway prototype implementation directly or carrying its rejected ledger/briefing variants or a production theme selector.

## Further Notes

### Accepted assumptions used by this draft

- The accepted domain glossary and ADRs are authoritative where older issue comments were superseded. In particular, automatic evidence-gated publication supersedes manual approval, and query-parameter language selection supersedes locale-prefixed paths.
- Rico Trevisan is the single authenticated editor/operator for the MVP, but the authentication technology has not been selected.
- French canonical copy may be generated or edited, and Dutch/English may be machine translated, but the processor/provider selection remains replaceable and versioned.
- A review case is the canonical unit of actionable editorial ambiguity; an Oban failure is not automatically a review case until domain retry policy classifies it as actionable.
- Neutral meeting publication can cite mentions and authoritative municipal facts without publishing sensitive derived relationships. Company enrichment is additive and asynchronous.
- The private archive exists for evidentiary reproducibility, while public verification uses authoritative publisher links plus optional retrieval/checksum metadata.
- Existing Coolify PostgreSQL and rustFS are provisioned with dedicated brussels.wtf logical namespaces before production release. The application validates but does not create those namespaces.

### Known gaps to resolve in implementation tickets

- **Authentication:** select and threat-model the exact Phoenix authentication/session mechanism for Rico, including credential bootstrap, recovery, CSRF protection, session expiry, and protection of private artifacts and operational actions.
- **AI processors:** select providers/models, benchmark French generation and NL/EN translation quality, define cost budgets, timeouts, retry/fallback behavior, prompt/configuration versioning, and the threshold for creating a review case.
- **Extraction thresholds:** calibrate page-level Poppler acceptance and OCR routing against representative documents from all four communes.
- **rustFS client behavior:** provision a test bucket and prove endpoint, region/signing, path-style/addressing, scoped credentials, and representative upload behavior before choosing ReqS3 or the accepted ExAws fallback.
- **Production resource limits:** set measured queue concurrency and hard OCR CPU, memory, and wall-time values compatible with the shared host.
- **Relationship policy evolution:** keep editorial charter, journalistic-purpose, source-license, correction/right-of-reply, relationship wording, defamation, retention/removal, and UBO constraints current as the publication expands.
- **Public submission retention:** contact is retained for at most 90 days and at most 30 days after moderation; keyed anti-abuse values for at most 48 hours; bodies for 365 days; fingerprints and reviewer notes have explicit purge deadlines. Keep this policy current as the publication expands.
- **Fixture licensing:** decide which captured authoritative documents may be committed, stored privately for CI, or represented by minimal extracts.
- **Exact responsive design:** translate the selected timeline prototype behavior into production breakpoints and accessibility acceptance criteria without importing the prototype code blindly.
- **Recording matching:** determine whether direct/heuristic recording links become a useful later source type; written neutral publication does not depend on it.
- **Future-cycle observation:** monitor several municipal meeting cycles to refine source update timing and confirm how frequently stable URLs are overwritten.

### Delivery note

This specification is intended to be decomposed into dependency-aware tracer-bullet implementation tickets. The first ticket set should prove the shared domain/storage skeleton and one Ixelles meeting from captured municipal index fixture to immutable source version, normalized proposal state, complete multilingual publication, later final-decision revision, and rendered meeting page. Subsequent tickets should add the three remaining adapter-specific behaviors, review dispositions, public dossier corrections, production storage validation, and automated evidence-gated relationship surfaces.
