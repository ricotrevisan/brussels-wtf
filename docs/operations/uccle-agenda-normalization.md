# Uccle agenda normalization (issue #148)

New Uccle agendas normalize and publish without an operator. This retry is a one-off for the
agendas that arrived before the normalizer shipped. Layout findings:
`docs/research/2026-11-03-uccle-agenda-layouts.md`.

## Retry stale agendas

Run in a remote console on the deployed release:

```elixir
path = Application.app_dir(:brussels_wtf, "priv/ops/retry_uccle_agendas_20261103.exs")

# 1. Dry run. Changes nothing.
Code.eval_file(path)
```

Check that `normalizer_loaded` is `true`, `coverage_mode` is `:paid`, `month_budget` leaves room
under `monthly_budget_cents`, and the 2026-10-15 candidates show `{:ok, ...}` with 58 and 40 items.
2026-09-10 candidates must show `{:skip, :recorded_corpus_meeting}`.

```elixir
# 2. Retry the complementary agenda only.
Code.eval_string(File.read!(path), apply?: true, limit: 1, actor_id: "<reviewer id>")
```

Wait until the page is live in FR, NL and EN at `/meetings/{id}`, then repeat step 2 once for the
base agenda. Base second changes no publication input and spends nothing.

A retry never covers more than 25 runs, and a candidate with an unclean preview is never retried.
An ambiguity opens a review case that blocks the page: read it in the review inbox.
