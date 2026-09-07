# Public Evidence Graph and Follow Product Specification

## Problem Statement

The MVP can publish municipal meetings and narrowly verified person and legal-entity facts, but citizens cannot yet inspect safe paths between those facts or follow the public resources that matter to them. A conventional graph or a generic “connected to” feature would create a second source of truth and invite unsupported conclusions from mentions, matching names, management roles, or proximity. Follow state also creates personal data and cannot be mixed with public collections, editorial authentication, or inferred entities.

This slice must make verified public facts easier to navigate without implying influence, conflict, ownership, misconduct, or any other derived conclusion. It must introduce the next official evidence sources in a deliberate order, with a separate fail-closed verifier and legal/access validation for each. It must also provide useful anonymous following, optional durable citizen accounts, shareable collections, clear retention, and deletion behavior without weakening Rico's separate editor boundary.

## Solution

Extend the Phoenix/Ash application with a public evidence projection over typed, time-bounded, verified facts already stored in PostgreSQL. PostgreSQL remains the sole fact store. Public pages render `Verified facts` and short `Fact paths`; each edge has neutral source-native wording, an applicable date, and its own citation. A path has at most two edges and is never summarized as a direct relationship or conclusion.

Add evidence adapters in this order: Belgian Official Gazette management appointments and cessations, Brussels public-mandate declarations, then TED result/award notices. Each adapter begins with a legal/access and representative-fixture validation spike and has its own identity, document-type, correction, wording, privacy, and fail-closed rules. CBE Open Data remains the legal-entity identity spine. Below-TED Belgian procurement and UBO data remain excluded.

Let citizens follow public dossiers, people, legal entities, and communes by stable public identifier. Keep a personal follow feed, its updates, and read state separate from shareable follow collections. Anonymous personal state stays browser-local. Anonymous visitors can still create a collection through separate public-view and secret-management URLs. Registered citizens use single-use AshAuthentication email magic links and may sync follows and use on-site notifications. Email notifications are deferred.

## User Stories

### Verified facts and fact paths

1. As a reader, I want public facts to come from verified PostgreSQL records, so that a graph view cannot invent a second source of truth.
2. As a reader, I want person, legal-entity, meeting, and dossier pages to show `Verified facts`, so that source-backed roles and events are easy to inspect.
3. As a reader, I want `Fact paths` to contain at most two edges, so that the interface stays close to the underlying evidence.
4. As a reader, I want every edge to show a neutral exact label, applicable date or period, and citation, so that I can check each fact independently.
5. As a reader, I want current facts before clearly separated dated history, so that ended or superseded facts are not presented as current.
6. As a person named in a source, I want mentions and uncertain identity matches excluded from public paths, so that reference alone does not become a relationship.
7. As a reader, I do not want a fact path described as a connection, influence, conflict, ownership, or misconduct unless a separately supported claim explicitly says that, so that the interface does not derive conclusions.
8. As an editor, I want routes, navigation, feeds, and indexing to fail closed when any fact fails identity, evidence, wording, date, or privacy policy.

### Official evidence expansion

9. As a reader, I want Gazette appointment and cessation facts to use the source's exact management or governance role, so that management is never widened to ownership.
10. As a reader, I want public mandates tied to the declaring authority and reporting period, so that an annual declaration is not treated as timeless.
11. As a reader, I want a contract award shown only from a TED result/award notice with a winning result, so that a tender or opportunity is never presented as an award.
12. As an operator, I want every evidence source to pass a legal/access validation spike before implementation, so that access, reuse, linking, excerpts, and retention are explicit.
13. As an editor, I want source-specific verifiers to create review cases on ambiguity or drift, so that an “official PDF” label alone never verifies a fact.

### Personal following

14. As a visitor, I want to follow a public dossier, person, legal entity, or commune, so that I can return to relevant updates.
15. As a visitor, I want anonymous follows and read state stored only in my browser, so that I can use follow without an account.
16. As a visitor, I understand that browser-local state does not sync and is lost when browser data is cleared.
17. As a registered citizen, I want my personal follow feed, updates, and read state synced across sessions.
18. As a registering citizen, I want to select which browser-local follows to import, so that registration does not silently copy all local state.
19. As a citizen, I want updates linked to the exact public revision or verified fact, so that notifications remain traceable.
20. As a citizen, I want only on-site notifications in this slice, so that email delivery is not implied.

### Follow collections

21. As a visitor, I want to create a shareable collection of public resources without putting my read state or notification history in it.
22. As an anonymous collection creator, I want separate public-view and secret-management URLs, so that viewing does not grant editing authority.
23. As an anonymous creator, I want new collections to default to unlisted.
24. As a collection owner, I want public, unlisted, or private visibility where authentication permits it.
25. As an invited registered citizen, I want a private collection share to be view-only, so that only its owner can change membership or visibility.
26. As a reader, I want public collections to use generated titles and no user-authored descriptions, so that the first slice does not add an unmoderated publishing surface.
27. As a citizen, I want importing collection members to create a snapshot, so that later collection edits do not silently change my personal follows.
28. As a registering citizen, I want claiming an anonymous collection to be a separate choice from importing browser-local personal follows.
29. As an operator, I want unused anonymous collections to expire after 12 months.

### Citizen authentication and deletion

30. As a citizen, I want a single-use email magic link that expires after 15 minutes, so that I do not need a password.
31. As a citizen, I want sessions to expire after 30 idle days or 90 absolute days and use secure cookies.
32. As an editor, I want citizen authorization to remain wholly separate from Rico's review-inbox session and privileges.
33. As an inactive citizen, I want warnings 30 and 7 days before deletion after six months without a sign-in.
34. As a citizen, I want immediate self-service account deletion with explicit handling of my personal state, shares, and owned collections.

## Implementation Decisions

### 1. Scope and principal seam

The principal acceptance seam is: an authoritative source observation creates or supersedes a typed verified fact; an eligible public page renders that fact as a neutral cited edge; a citizen follows the public resource; and a qualifying later public change creates an on-site update linked to the exact revision or fact.

The first followable resource types are dossiers, people, legal entities, and communes. Individual meetings and free-form topics or saved searches are excluded. Only stable, already-public identifiers may be followed or collected. Private mentions, review cases, unpublished resources, and unverified facts are never valid targets.

### 2. Evidence projection

The public evidence graph is a read/query projection from PostgreSQL relationship claims and evidence. Do not add a graph database, a vague connection-edge table, or a second verification state. Projection code selects only allowlisted typed facts with `verified` status whose identity, authoritative evidence, wording, dates, privacy, and publication rules currently pass.

A fact path contains one or two individually publishable edges. Each edge retains its fact identifier, source-native type, endpoints, effective date or reporting period, current/ended/superseded state, and citation. The path is a presentation result only. It is not persisted as a new relationship and does not establish a direct fact between its endpoints.

Ended and superseded facts may remain as dated history where lawful and relevant. Current facts sort first. Public removal or correction of one edge immediately removes every projected path that depends on it; the underlying audit history remains governed by the existing immutable evidence model.

### 3. Public presentation and wording

Person, legal-entity/company, meeting, and dossier pages may contain sections named exactly `Verified facts` and `Fact paths`. Allowed labels are precise neutral predicates such as `director of`, `council member of`, and `contract awarded to`, localized into complete FR/NL/EN variants without changing semantics.

Every edge displays a citation and applicable date or period next to the label. The interface must not use `connections`, `influence`, `conflicts`, or language that turns co-occurring facts into a conclusion. A two-edge path must remain visually and semantically two facts. It must not be collapsed into prose asserting a direct relationship.

Private addresses, signatures, contact details, identity numbers, family information, and private corroborators never appear. Navigation, feeds, structured data, indexing, and direct routes use the same eligibility query as page rendering and fail closed rather than leaking a hidden or rejected edge.

### 4. Source delivery sequence and validation spikes

Implement evidence sources in this order:

1. Belgian Official Gazette legal-person annexes for management/governance appointments and cessations.
2. Brussels authority and municipal public-mandate declarations.
3. TED result/award notices for public-contract awards.

Before each adapter is enabled, complete a legal/access spike that records the authoritative endpoint, access method, reuse terms or uncertainty, allowed public excerpt/link policy, source/version identity, correction behavior, representative FR/NL fixtures, and prohibited fields. The spike must produce acceptance fixtures for valid, invalid, corrected, ambiguous, and layout-drift cases. Unresolved legal/access questions block that source, not the earlier sources.

CBE Open Data is the legal-entity identity spine, subject to its separately accepted license. Do not scrape or systematically ingest CBE Public Search. Below-TED procurement remains deferred until API, immutable version, and reuse rules are established. UBO remains excluded.

### 5. Trusted verifier contracts

All source verifiers pin publisher, canonical locator, retrieval observation, immutable bytes/hash, document or notice identity, publication time, language, parser version, excerpt/location, and applicable period. They validate the source-specific record type before emitting an allowlisted claim. Ambiguity, source conflicts, missing fields, identity uncertainty, layout drift, or unsupported reuse creates a review case and publishes nothing.

Gazette verification requires a matching valid CBE enterprise number, an operative appointment or cessation, the exact source role, and a supported decision/effective-date interpretation. Publication time is not substituted for effective time. A management role never establishes shares, beneficial ownership, control, or current status beyond the evidence period.

Mandate verification requires the responsible authority's publication, year/version, exact person and role row, table scope, and reporting period. It preserves distinctions among mandates, functions, derived functions, and any separately allowed remuneration-band fact. It does not infer a company identity, conflict, or activity outside the declared period.

TED verification requires an authentic result/award notice, a winning result, matched lot, buyer and winner identity, current correction chain, date, currency, value, and value basis. Competition, prior-information, and tender notices cannot establish awards. Cancelled and no-winner lots emit no supplier-award edge. Estimated, framework-maximum, contract, and lot values are not interchangeable.

Legal entities resolve by validated registry identifier. A natural person resolves only through an explicit identifier or exact name plus an independent corroborating fact under `CONTEXT.md`. Name similarity, mentions, shared addresses, and model inference remain private signals.

### 6. Personal follow feed and update generation

A personal follow feed stores citizen-private target references, update entries, and read state. Anonymous personal state is browser-local only and is not written to the server. It has no sync or recovery promise. Registration presents an explicit selection of local targets to import.

Registered feed updates are generated only for these public events:

- dossier: linked agenda item, decision, correction, merge, or split;
- person: new or changed verified public mandate or management role, or newly published relevant council item;
- legal entity: new or changed verified management role, contract award, or relevant council item;
- commune: newly published meeting page or a publication revision containing new decisions.

Typography-only edits, retrieval observations, private review activity, and unverified facts do not generate updates. Update creation is idempotent on citizen, target, and public event/revision. Each entry links to the exact localized public resource, revision, or verified fact. The first transport is on-site only. Email, push, and external notification delivery are deferred. Notification entries and read state are retained for at most 12 months.

### 7. Follow collections and sharing

A follow collection is a named list of public target references. It contains no personal feed membership, read state, notification state, or implication that its creator personally follows every member. First-slice titles are generated deterministically from collection contents or creation context. User-authored descriptions are not supported.

Visibility is `public`, `unlisted`, or `private`. Anonymous collections default to `unlisted` and have an unguessable public-view capability URL plus a separate unguessable secret-management capability URL. Management secrets are stored as one-way hashes, are never logged, and can change membership or delete the collection. Public and unlisted view URLs never grant management. Anonymous collections with no qualifying use for 12 months expire; implementation tickets must define a conservative `last_used_at` update that cannot be kept alive by indiscriminate crawler traffic.

Registered owners may choose all three visibility modes. Private collections are visible only to the owner and explicitly invited registered users. Shares are view-only. Only the owner changes membership, title generation inputs, visibility, invitations, or ownership. Public collections are indexable; unlisted and private collections are not. All collection views remain available anonymously when public, including those owned by registered users. Unlisted capability links may be viewed anonymously. Private shares require the invited citizen session.

Importing selected collection members into a personal feed is a point-in-time snapshot. Later collection changes never add or remove another citizen's follows. Claiming ownership of an anonymous collection during registration is a separate explicit action from importing personal follows.

### 8. Citizen authentication and sessions

Citizen accounts use AshAuthentication email magic links. A token is single-use, stored safely, and expires 15 minutes after issue. Responses must not reveal whether an email address has an account. Rate limits and audit events must avoid retaining raw secrets.

Citizen cookies are `Secure`, `HttpOnly`, and `SameSite=Lax`. A session expires after 30 days without authenticated activity and after 90 days regardless of activity. Email change and account deletion revoke all citizen sessions. CSRF and session-rotation behavior follow Phoenix/AshAuthentication secure defaults and receive explicit integration tests.

Citizen identities and authorization are separate from Rico's editor identity, session, routes, and roles. No citizen account, collection ownership, invitation, or magic-link flow can grant review-inbox, private artifact, suggestion contact, operational, or publication privileges.

### 9. Account inactivity and deletion

Account activity for retention means successful sign-in; receiving an email or passively loading a page is not activity. After six months since last sign-in, schedule deletion and send warnings 30 and 7 days before the deletion date. A later successful sign-in cancels the pending deletion and resets the inactivity clock.

Immediate self-service deletion must atomically or resumably:

- remove the email identity and revoke all sessions and outstanding magic links;
- delete personal follows, notification entries, and read state;
- delete grants to private collections and the citizen's membership in collections shared by others;
- delete every owned private collection and its grants;
- require every owned public or unlisted collection to be transferred to another registered account or deleted before account deletion completes.

Public or unlisted collections cannot become ownerless. Transfer requires acceptance by the recipient. If an inactivity deletion reaches an account that still owns such a collection, the deletion workflow must resolve it by the preselected transfer or deletion choice; it must not silently publish, privatize, or orphan it. Retain only the minimum non-identifying deletion audit needed to prove completion and prevent unsafe retries. Do not retain the email, follow list, collection memberships, or notification history in that audit.

## Testing Decisions

### Principal acceptance scenarios

- A valid Gazette cessation supersedes a current management role. Public pages show the dated history, remove paths that depended on the current role, and create one eligible follower update.
- A Gazette act with a matching company name but mismatched CBE number creates a review case and no edge, route, path, index entry, or notification.
- A mandate declaration produces a dated `council member of` edge; a two-edge path shows two citations and no derived direct relationship.
- A TED tender notice and a no-winner result produce no award. A corrected winning result produces one `contract awarded to` edge with the correct lot and value basis.
- Removing eligibility from either edge of a two-edge path removes the path everywhere, including structured data and feeds.
- Anonymous follows survive ordinary navigation in one browser but are absent in another. Clearing browser data removes them.
- Registration imports only selected browser-local follows and does not claim an anonymous collection unless separately requested.
- An anonymous collection defaults to unlisted. Its view URL cannot manage it, its management URL can, and it expires after 12 unused months.
- Public and unlisted collections can be viewed anonymously. Private collections require an invited registered session and remain view-only for invitees.
- Importing a collection is a snapshot; later owner edits do not modify the importing citizen's feed.
- Magic links reject reuse and use after 15 minutes. Sessions enforce idle and absolute expiry and cookie attributes.
- A citizen session cannot reach any editor capability.
- Self-service and inactivity deletion execute the exact personal-data and collection policy, revoke sessions, and leave only a non-identifying audit.

### Focused lower seams and gates

Use source-adapter contract tests with representative authoritative fixtures, policy/property tests over verification and path combinations, PostgreSQL query tests proving projection eligibility, authorization tests for every visibility/capability boundary, controlled-clock tests for token/session/retention deadlines, and browser tests for local-state import and accessible no-JavaScript public views.

No source is complete until its access spike is accepted and valid, invalid, ambiguity, correction, and drift fixtures pass. No fact path is complete unless every edge independently renders a date and citation in FR/NL/EN. No follow slice is complete unless update generation is idempotent and private state is absent from public collection responses, logs, indexing, and analytics.

## Out of Scope

- A graph database or persisted vague connection edges.
- Paths longer than two edges, graph exploration canvases, ranking people by connectivity, or inferred direct relationships.
- Claims of influence, conflict, wrongdoing, misconduct, ownership, or control derived from other facts.
- Publishing mentions, name matches, shared-address signals, model inference, or private corroborating data.
- UBO ingestion or publication.
- Below-TED Belgian procurement until its access, versioning, and reuse questions are resolved.
- Treating tender notices as awards or management as ownership.
- Following individual meetings, free-form topics, queries, or private/unpublished resources.
- Email, push, SMS, newsletters, digests, and other off-site notifications.
- User-authored collection titles or descriptions, collaborative collection editing, comments, and reactions.
- Anonymous cross-device personal-feed sync or recovery.
- Reusing citizen authentication for editor access.

## Further Notes

### Traceability

This specification consolidates the accepted decisions in issues [#35](https://github.com/ricotrevisan/brussels-wtf/issues/35), [#36](https://github.com/ricotrevisan/brussels-wtf/issues/36), [#37](https://github.com/ricotrevisan/brussels-wtf/issues/37), [#38](https://github.com/ricotrevisan/brussels-wtf/issues/38), and [#39](https://github.com/ricotrevisan/brussels-wtf/issues/39), for the parent specification issue [#40](https://github.com/ricotrevisan/brussels-wtf/issues/40). Source-specific research and remaining legal/access questions are recorded in [`docs/research/public-evidence-sources.md`](../research/public-evidence-sources.md). Domain meanings and evidence/privacy constraints remain governed by [`CONTEXT.md`](../../CONTEXT.md) and the base [`mvp-implementation.md`](mvp-implementation.md).

### Delivery note

Decompose this specification into dependency-aware tracer bullets. Start with the shared verified-fact projection and one Gazette validation/fixture path. Then add neutral rendering, a browser-local follow slice, server collections, citizen authentication and registered feeds, mandate verification, and TED verification. Every ticket must cite the relevant behavior above, state its source and privacy gates, and include explicit end-to-end acceptance criteria. Mark only the truly unblocked frontier `ready-for-agent`.
