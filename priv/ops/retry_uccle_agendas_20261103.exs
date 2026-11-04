# Retry stale Uccle agenda normalization for issue 148, through the normal review path.
# Run on the deployed release, after the release containing BrusselsWtf.Processors.UccleCouncil:
#   Code.eval_file(Application.app_dir(:brussels_wtf, "priv/ops/retry_uccle_agendas_20261103.exs"))
# Default is read-only: it previews each candidate and changes nothing.
# Applying requires explicit bindings, for example:
#   path = Application.app_dir(:brussels_wtf, "priv/ops/retry_uccle_agendas_20261103.exs")
#   Code.eval_string(File.read!(path), apply?: true, limit: 1, actor_id: "<reviewer id>")
#
# Scope: open "normalization unavailable" cases on Uccle agenda documents of meetings from
# 2026-09-01. A recorded corpus meeting is never retried: its published page must stay
# byte-identical, and its unlinked sources do not block any publication gate.
#
# Order: newest meeting first, complementary agenda before base. Apply one run, wait for the
# page, then apply the next: a base agenda retried after its complementary agenda changes no
# publication input and spends nothing, whereas the reverse order pays to publish twice.
#
# A retry re-extracts the archived bytes, resolves the stale case once extraction is accepted,
# and normalizes through the normal queues. Publication then follows automatically under the
# monthly budget. A candidate whose preview is not clean is reported and never retried.
options = Map.new(binding())
apply? = Map.get(options, :apply?, false)
limit = Map.get(options, :limit, 1)
actor_id = Map.get(options, :actor_id)
from = ~D[2026-09-01]

if apply? and not is_integer(limit), do: raise("limit must be an integer")
if apply? and limit < 1, do: raise("limit must be positive")

if apply? and limit > 25,
  do: raise("refusing to retry more than 25 runs without a new decision")

if apply? and (not is_binary(actor_id) or String.trim(actor_id) == ""),
  do: raise("actor_id must name the authenticated reviewer")

alias BrusselsWtf.Corpus.Manifest
alias BrusselsWtf.Ingestion.Pipeline
alias BrusselsWtf.Processors.UccleCouncil
alias BrusselsWtf.Review
alias BrusselsWtf.Review.Actor

candidates_sql = """
SELECT rc.id::text, r.id::text, l.role, l.meeting_identifier, l.scheduled_on, v.sha256
FROM review_cases rc
JOIN source_versions v ON v.id = rc.source_version_id
JOIN source_records s ON s.id = rc.source_record_id
JOIN communes c ON c.id = s.commune_id
JOIN source_locators l ON l.url = s.origin_url AND l.commune_id = c.id
JOIN processing_runs r ON rc.processing_generation = 'normalization:' || r.id::text
WHERE c.slug = 'uccle'
  AND rc.kind = 'normalization'
  AND rc.status = 'open'
  AND rc.diagnostics->>'classification' = 'processor_unavailable'
  AND l.role IN ('agenda', 'complementary_agenda')
  AND l.scheduled_on >= $1
ORDER BY l.scheduled_on DESC, l.role DESC, rc.id
"""

%{rows: rows} = BrusselsWtf.Repo.query!(candidates_sql, [from])

squish = fn text -> text |> String.replace(~r/\s+/u, " ") |> String.trim() end

preview = fn run_id, meeting_identifier ->
  cond do
    Manifest.meeting_by_identity("uccle", meeting_identifier) ->
      {:skip, :recorded_corpus_meeting}

    true ->
      input =
        run_id |> BrusselsWtf.Ingestion.get_processing_run!() |> Pipeline.normalization_input()

      case BrusselsWtf.Processors.normalize(input) do
        {:ok, normalized} ->
          items = normalized["items"]
          proposals = Enum.flat_map(items, &Map.get(&1, "proposals", []))

          {:ok,
           %{
             agenda: normalized["agenda"]["kind"],
             items: length(items),
             proposals: length(proposals),
             excerpts_shorter_than_wording:
               Enum.count(proposals, &(squish.(&1["evidence"]["excerpt"]) != &1["text"]))
           }}

        {:error, reason} ->
          {:skip, reason}
      end
  end
end

reviewed =
  Enum.map(rows, fn [case_id, run_id, role, meeting_identifier, scheduled_on, sha256] ->
    %{
      review_case_id: case_id,
      processing_run_id: run_id,
      role: role,
      meeting: meeting_identifier,
      scheduled_on: scheduled_on,
      sha256: sha256,
      preview: preview.(run_id, meeting_identifier)
    }
  end)

ready = Enum.filter(reviewed, &match?({:ok, _summary}, &1.preview))
coverage = Application.fetch_env!(:brussels_wtf, :coverage_generation)

%{rows: budget_rows} =
  BrusselsWtf.Repo.query!(
    "SELECT reserved_cents, spent_cents FROM coverage_budgets WHERE period_start = date_trunc('month', now())::date"
  )

month_budget =
  case budget_rows do
    [[reserved, spent]] -> %{reserved_cents: reserved, spent_cents: spent}
    [] -> %{reserved_cents: 0, spent_cents: 0}
  end

IO.inspect(
  %{
    generate: "issue-148-uccle-agenda-retry",
    read_only: not apply?,
    from: from,
    normalization_contract: BrusselsWtf.Processors.normalization_contract(),
    normalizer_loaded: Code.ensure_loaded?(UccleCouncil),
    coverage_mode: coverage.mode,
    monthly_budget_cents: coverage.monthly_budget_cents,
    month_budget: month_budget,
    candidate_count: length(reviewed),
    ready_count: length(ready),
    candidates: reviewed
  },
  limit: :infinity,
  printable_limit: :infinity
)

if apply? do
  actor = %Actor{id: actor_id, role: :reviewer}

  results =
    ready
    |> Enum.take(limit)
    |> Enum.map(fn candidate ->
      candidate.review_case_id
      |> Review.get_review_case!(actor: actor)
      |> Review.retry_review_case!(
        %{note: "Issue 148: retry with the Uccle agenda normalizer"},
        actor: actor
      )

      %{
        review_case_id: candidate.review_case_id,
        meeting: candidate.meeting,
        role: candidate.role
      }
    end)

  IO.inspect(%{applied: length(results), results: results}, limit: :infinity)
else
  IO.puts("read-only: nothing was retried. Pass apply?: true, limit:, actor_id: to retry.")
end
