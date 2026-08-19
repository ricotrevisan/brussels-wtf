# Automatic meeting-page publication

[#17: Generate and publish upcoming Ixelles coverage](https://github.com/ricotrevisan/brussels-wtf/issues/17) adds evidence-gated automatic publication.

## Flow

1. Normalization persists the current meeting, agenda items, proposals, and official evidence.
2. A `publish`-queue job rebuilds a deterministic publication input from that stored state.
3. The configured processor generates canonical French coverage, then translates that exact output to Dutch and English.
4. Every execution is retained as an immutable coverage run with input/output hashes, processor version, configuration hash, timing, usage, and its canonical-parent relationship.
5. The publication gate checks complete page and item variants, normalized claim references, official evidence and citations, applicable provenance, and a coherent current run chain.
6. The page becomes public only after the complete revision passes. No reviewer approval is required.

Initial draft variants remain private, so a failed or interrupted generation cannot expose a partial locale. Once the initial page is published, generated variants remain unchanged until the later revision workflow is implemented.

## Gate failures

A failed gate leaves the page in `draft`, stores typed failure details on the page, and opens one deduplicated `publication` review case for the publication-input hash. The review case contains durable identifiers and classifications, not provider prompts, credentials, or private object keys.

Common failure codes include:

- `missing_page_variant`
- `missing_coverage_variant`
- `missing_official_evidence`
- `unsupported_claim_reference`
- `missing_provenance`
- `stale_generation`

## Processor configuration

The processor is selected through the `:brussels_wtf, :processors` application configuration. Ordinary tests use recorded deterministic outputs and perform no paid or nondeterministic calls. Production remains unimplemented until a provider is selected and benchmarked; the domain contract does not depend on that choice.
