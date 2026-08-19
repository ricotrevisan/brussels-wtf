# Automatic meeting-page publication

[#17: Generate and publish upcoming Ixelles coverage](https://github.com/ricotrevisan/brussels-wtf/issues/17) adds evidence-gated automatic publication.

## Flow

1. Normalization persists the current meeting, agenda items, proposals, and official evidence.
2. A `publish`-queue job invokes the named `generate_coverage` Ash action, which rebuilds a deterministic publication input from that stored state.
3. The configured coverage processor generates canonical French coverage, then translates that exact output to Dutch and English.
4. Every processor execution, including a failed or exceptional call, is retained as an immutable coverage run with input/output hashes, processor version, configuration hash, method, timing, usage, failure classification, and canonical-parent relationship.
5. The named publication-gate action checks complete page and item variants, normalized claim references, official evidence and citations, applicable provenance, a coherent current run chain, and the absence of open normalization or evidence review cases for the meeting.
6. The page becomes public only after the complete revision passes. No reviewer approval is required.

The variant upserts and page publication happen in one database transaction. A failed or interrupted initial generation leaves a private draft. A failed later revision preserves the complete prior public revision. A complete later generation atomically replaces all locale variants and updates the published revision.

## Failures and retry

A gate failure preserves the last complete publication state, stores typed failure details on the page, and opens one deduplicated `publication` review case for the publication-input hash. A later successful generation resolves that gate case. Common failure codes include:

- `missing_page_variant`
- `missing_coverage_variant`
- `missing_official_evidence`
- `unsupported_claim_reference`
- `missing_provenance`
- `stale_generation`
- `blocking_review_case`

Processor failures retain one coverage-run record per execution. Oban retries them up to its bounded `max_attempts`; the terminal attempt opens a deduplicated high-urgency publication review case. Diagnostics contain durable identifiers and safe classifications, never provider prompts, credentials, private object keys, or response bodies.

## Processor configuration

Coverage generation is selected through the `:brussels_wtf, :coverage_processor` application configuration, independently of extraction and normalization. Production uses a deterministic recorded contract for the initial Ixelles proposal. Tests use a fixture-backed stub and make no paid or nondeterministic calls. A later benchmark may replace the provider through the same processor seam without changing the publication contract.
