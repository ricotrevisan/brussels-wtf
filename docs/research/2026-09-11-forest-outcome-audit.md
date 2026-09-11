# Forest 24 March 2026 outcome audit

- Issue: [Repair audited production content and interface defects](https://github.com/RicoTrevisan/brussels-wtf/issues/77).
- Audit date: 11 September 2026.
- Scope: Forest items 9 and 15. No new decision, glossary term, enum, or ADR.
- No production mutation or paid generation was performed by this audit.

## Immutable official evidence

[Official public minutes][minutes], published by the municipality of Forest.
The existing manifest discovered the PDF through the [official council index][index].
One bounded HTTPS download on 11 September 2026 returned the same bytes as the sealed corpus:

- SHA-256: `6e31a35822196823ecba87cbd4b185ad7eb92e4c99cf6c86f441867a86086d26`.
- Length: 568,679 bytes. Download limit: 2,000,000 bytes and 45 seconds.
- Download completed: `2026-09-11T10:40:02Z` (UTC).
- Existing corpus retrieval: `2026-08-21T13:48:13.895Z`; that historical timestamp is unchanged.
- Existing private bundle: `priv/corpus/issue-33/sources/forest-2026-03-24--primary.pdf`.
- Poppler native extraction: `pdftotext -layout`, 92 numbered pages.

No additional PDF or full extracted text was added to Git. The source bundle and source hash are unchanged.
Only non-private operative procurement clauses are quoted below.

### Item 9 — newspaper production, printing and distribution

French pages **30–31/92**, Dutch pages **31–32/92**.
The heading says “Application de l’article 234 §3 de la Nouvelle loi communale – Information”.
Under `DECIDE:`, the operative clause starts:

> De prendre connaissance des décisions du Collège des Bourgmestre et Échevins des 13 et 27 novembre 2025 relatives à la passation d'un marché public de services ayant pour objet “Réalisation, impression et distribution du journal communal” (SCA-2026-S-004)

The clause records the estimated EUR 142,020 excluding VAT / EUR 154,834.20 including VAT and the request for credits for 2026–2028. It then records:

> Le Conseil approuve le projet de délibération. 32 votants : 32 votes positifs.

Dutch corroboration: `BESLIST` / “Kennis te nemen van de beslissingen van het College van Burgemeester en Schepenen van 13 en 27 november 2025”.

### Item 15 — urgent glazing work at Saint-Denis church

French pages **45–46/92**, Dutch pages **46–47/92**.
The operative clause on page 46 starts:

> DECIDE (sous réserve de l’approbation de la Tutelle) : De prendre connaissance de la décision du Collège des bourgmestre et échevins du 12 février 2026 faisant choix de la procédure par la facture acceptée (marchés publics de faible montant)

It names `MP-2026-T-001`, estimates EUR 9,004.13 excluding VAT / EUR 10,895 including VAT, and records financing by borrowing. It then records:

> Le Conseil approuve le projet de délibération. 32 votants : 32 votes positifs.

Dutch corroboration on page 47: `BESLIST (onder voorbehoud van goedkeuring door de toezichthoudende overheid)` / “Kennis te nemen van de beslissing van het College van Burgemeester en Schepenen van 12 februari 2026”.

## Finding and bounded correction

The council passed both acknowledgement resolutions. This audit does **not** deny that vote or assert rejection, postponement, or a later municipal reversal.
However, the generic `Approved` badge next to each contract title blurred approval of an acknowledgement resolution with approval of the underlying procurement. The operative act is taking note of executive decisions.

Use the existing `other` disposition for these two acknowledgement outcomes. Their FR/NL/EN summaries already describe that act correctly and stay unchanged. The existing localized disposition labels (`autre`, `andere`, `other`) are correct generic fallbacks; they must not be globally renamed “took note”, because other kinds of outcome also use this enum.

Expand the claim-specific excerpts to retain the acknowledgement **and** the approval/vote boilerplate. Item 15 also retains its supervisory-approval condition. The real-PDF normalizer verifies these exact excerpts inside the declared page bounds. Item 20, a budget allocation on pages 57–58, remains `approved`.

## Publication lifecycle defect proved by this audit

Previously, `PublicationLifecycle.factual_correction!/4` wrote new locale variants and a dated revision but did not advance agenda items' public decision pointers. A corrected normalized `other` outcome could therefore still render `Décision: approuvée`.

The correction now advances only the scoped items' public normalized state, only for a **factual** correction, only after the publication gate passes, and inside the same database transaction as all FR/NL/EN variants and the immutable revision. It does not rewrite old `Decision` rows, source versions, or prior publication revisions. Typography-only corrections do not advance these pointers.

Acceptance coverage uses the real sealed Forest PDF and the public meeting routes. It proves:

- Both operative acknowledgement and 32-vote approval text survive normalization.
- Current FR/NL/EN badges are `other`; genuine item 20 approval remains approved.
- Re-normalization alone leaves the previous public badge and revision unchanged.
- A blocking evidence case rolls back the attempted factual correction, including variants/runs/revision/public pointers.
- A successful factual correction moves all locale badges together and preserves the previous `approved` interpretation and its immutable publication input.
- No municipal HTTP call, source replacement, or paid generation is needed.

## Safe publication procedure — no SQL

Deploy the fixed release first. Do not edit a completed corpus import batch or replay the whole eight-meeting release just to repair this page.

1. Read the current Forest page by `Council.get_published_meeting_page("forest", "2026-03-24")`. Retain its current revision ID and three source-backed item keys. Stop if the scope is not exactly items 9, 15, and 20, or the current source hash differs from the hash above.
2. Use `Publication.load_meeting/1` and `PublicationScope.restore!/2` with the prior revision's `canonical_run.input` to retain the exact public item scope. Retain the old input and decision IDs for the audit.
3. Select the successful accepted native-extraction run belonging to the hash-pinned source version. Its private text artifact must still exist. `Ingestion.Pipeline.normalize(run.id, official_url, 1, 3, :backfill)` validates its checksum, runs the corrected recorded normalizer, and appends source interpretations. The `:backfill` argument prevents automatic publication enqueueing. It does not perform paid coverage generation.
4. Record/resolve a specifically scoped evidence review case through `Review.open_review_case!/1` and authenticated `Review.correct_review_case!/3`. Store old/new outcome mappings, source hash, page locations, issue URL, and normalization contract digest. The review `correct` action alone **does not** change normalized or public content; it retains the audit revision.
5. Rebuild the same scoped publication input. Produce FR/NL/EN bundles with `Manifest.recorded_bundle(input, locale)`. Each result must be `{:ok, bundle}`; this independently checks the exact meeting, claims, dispositions, and official evidence against the current manifest. Stop on any mismatch or open blocking evidence case.
6. Call `Publication.recorded_factual_correction!(page.id, expected_revision_id, notes, actor)`. It generates its own bundles through the configured recorded processor; callers cannot provide copy or provenance. It locks and checks the expected revision, restores its exact scope, uses the existing generation and evidence gate, and publishes all three variants and their public dispositions in one dated factual revision. Verify its parent, gate, locale set, source hash, public badges, correction notes, anchors, and preserved prior decisions/revision.

**Provenance guard:** `PublicationLifecycle.factual_correction!/4` remains the human editorial action and adds `human-reviewed`. Do not use it for this agent-only correction. The new `Publication.recorded_factual_correction!/4` records the actual configured AI/translation methods. Its actor records authorization, not human review. It rejects disabled/paid modes, network-backed processors, human-edit methods, and supplied human-review metadata. It does not carry human-reviewed labels from an earlier revision into the changed content.

The same expected-parent/input/notes/processor-config request returns its existing revision without new runs. A different parent, input, note, or processor config fails as stale. Both the outer correction operation and the shared final publication transaction lock/check the page. Failed gates or incomplete translations leave public variants, pointers, and history unchanged. This recorded-only operation rolls back its attempted runs on failure; ordinary automatic generation retains its existing behavior.

### Release operator invocation

The release includes [`priv/ops/correct_forest_20260324.exs`](../../priv/ops/correct_forest_20260324.exs). It implements the guards, source re-normalization, review audit, and named publication call above. Run only in an authenticated operator session authorized for this correction. No direct SQL is used. Default execution is read-only:

```sh
bin/brussels_wtf rpc 'Code.eval_file(Application.app_dir(:brussels_wtf, "priv/ops/correct_forest_20260324.exs"))'
```

Record the printed `current_revision_id`, source SHA-256, and accepted extraction run ID. Inspect the source clauses and ensure there are no unresolved unrelated evidence cases. Then replace the two placeholders with that exact revision UUID and the configured reviewer actor ID:

```sh
bin/brussels_wtf rpc 'p = Application.app_dir(:brussels_wtf, "priv/ops/correct_forest_20260324.exs"); Code.eval_string(File.read!(p), [apply?: true, expected_revision_id: "PREFLIGHT_REVISION_UUID", actor_id: "CONFIGURED_REVIEWER_ID"], file: p)'
```

The bindings are local to this evaluation. They do not alter the running release's environment, generation mode, schedules, or provider settings. Use `rpc` against the existing release, not a second fully started application/worker instance. The script never fetches another municipal file, reimports the eight-meeting corpus, or calls a paid provider. It reads the existing private accepted text artifact; its checksum and evidence markers are checked by the normalizer. A preflight failure requires investigation, not bypassing the guard. If interrupted after re-normalization, the prior public revision remains visible and the operation can be retried with the original expected revision token.

Only isolated test execution of this operator script has occurred. Production application remains a separate authorized operator action.

Suggested synchronized notes:

- FR: L’étiquette « approuvée » des points 9 et 15 était trop générale : le conseil a approuvé une prise de connaissance des décisions du collège, non les marchés eux-mêmes.
- NL: Het label ‘goedgekeurd’ bij punten 9 en 15 was te algemeen: de raad keurde een kennisneming van collegebesluiten goed, niet de opdrachten zelf.
- EN: The Approved label on items 9 and 15 was too broad: the council approved acknowledgement of executive decisions, not the underlying contracts.

[minutes]: https://forest.brussels/sites/default/files/publications/registre/2026-03/PV%20%20conseil%20communal%20-%20gemeenteraad%2024032026.pdf
[index]: https://forest.brussels/fr/publications/conseil-communal-1

## Validation

Both defect regressions failed before their fixes: the real-corpus outcome was `approved`, and an editorial correction left the public French heading `Décision: approuvée`. The new recorded entrypoint also failed its initial acceptance test before implementation.

Final checks on the isolated worktree:

- 47 focused tests passed across corpus acceptance/import/manifest, publication generation/input/lifecycle, public reader/operations, and Forest principal-seam tests.
- The recorded Forest test executes the release operator script in read-only and apply modes against the isolated test database. It checks incomplete NL output, blocked evidence, stale/repeated requests, changed notes/config, disabled/paid modes, authorization, and truthful provenance.
- `mix format --check-formatted` and `mix compile --warnings-as-errors` passed.
- Environment: `ERL_FLAGS='+S 4:4'`, `MIX_TEST_PARTITION='_content_0911'`, `MIX_ENV=test`; build output isolated under `/tmp/brussels-incident-20260911/content-review-build`.

The full repository suite and production release/application checks are not claimed by this child audit.
