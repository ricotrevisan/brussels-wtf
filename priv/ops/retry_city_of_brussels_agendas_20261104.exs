# Retry stale City of Brussels agenda normalization for issue 150, through the normal review path.
# Run on the deployed release, after the release containing BrusselsWtf.Processors.CityOfBrusselsCouncil:
#   Code.eval_file(Application.app_dir(:brussels_wtf, "priv/ops/retry_city_of_brussels_agendas_20261104.exs"))
# Default is read-only: it previews each candidate and changes nothing.
# Applying requires explicit bindings, for example:
#   path = Application.app_dir(:brussels_wtf, "priv/ops/retry_city_of_brussels_agendas_20261104.exs")
#   Code.eval_string(File.read!(path), apply?: true, limit: 1, actor_id: "<reviewer id>")
#
# Scope: open "normalization unavailable" cases on City agendas, supplements and addenda of
# meetings from 2026-09-01. A recorded corpus meeting is never retried: its published page must
# stay byte-identical, and its unlinked sources do not block any publication gate.
#
# Order: newest meeting first, base agenda before supplement. Apply one run, wait for the page,
# then apply the next. A supplement adds points, so each document regenerates the page once.
#
# A retry re-extracts the archived bytes, resolves the stale case once extraction is accepted,
# and normalizes through the normal queues. Publication then follows automatically under the
# monthly budget. A candidate whose preview is not clean, or whose source holds another open
# normalization case that would block the gate after spending, is reported and never retried.
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
alias BrusselsWtf.Processors.CityOfBrusselsCouncil
alias BrusselsWtf.Review
alias BrusselsWtf.Review.Actor

# The City's listings can record one URL under several locators, hence DISTINCT ON the case.
candidates_sql = """
SELECT case_id, run_id, role, meeting_identifier, scheduled_on, sha256, other_open_cases
FROM (
  SELECT DISTINCT ON (rc.id)
    rc.id::text AS case_id, r.id::text AS run_id, l.role, l.meeting_identifier, l.scheduled_on,
    v.sha256,
    (SELECT count(*) FROM review_cases other
     WHERE other.source_record_id = rc.source_record_id AND other.id <> rc.id
       AND other.status = 'open' AND other.kind = 'normalization') AS other_open_cases
  FROM review_cases rc
  JOIN source_versions v ON v.id = rc.source_version_id
  JOIN source_records s ON s.id = rc.source_record_id
  JOIN communes c ON c.id = s.commune_id
  JOIN source_locators l ON l.url = s.origin_url AND l.commune_id = c.id
  JOIN processing_runs r ON rc.processing_generation = 'normalization:' || r.id::text
  WHERE c.slug = 'city-of-brussels'
    AND rc.kind = 'normalization'
    AND rc.status = 'open'
    AND rc.diagnostics->>'classification' = 'processor_unavailable'
    AND l.role IN ('agenda', 'supplement', 'addendum')
    AND l.scheduled_on >= $1
  ORDER BY rc.id
) candidate
ORDER BY scheduled_on DESC, CASE role WHEN 'agenda' THEN 0 WHEN 'supplement' THEN 1 ELSE 2 END, case_id
"""

%{rows: rows} = BrusselsWtf.Repo.query!(candidates_sql, [from])

preview = fn run_id, meeting_identifier, other_open_cases ->
  cond do
    Manifest.meeting_by_identity("city-of-brussels", meeting_identifier) ->
      {:skip, :recorded_corpus_meeting}

    other_open_cases > 0 ->
      {:skip, :other_open_normalization_case}

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
             proposals: length(proposals)
           }}

        {:error, reason} ->
          {:skip, reason}
      end
  end
end

reviewed =
  Enum.map(rows, fn [case_id, run_id, role, meeting_identifier, scheduled_on, sha256, other] ->
    %{
      review_case_id: case_id,
      processing_run_id: run_id,
      role: role,
      meeting: meeting_identifier,
      scheduled_on: scheduled_on,
      sha256: sha256,
      preview: preview.(run_id, meeting_identifier, other)
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
    generate: "issue-150-city-agenda-retry",
    read_only: not apply?,
    from: from,
    normalization_contract: BrusselsWtf.Processors.normalization_contract(),
    normalizer_loaded: Code.ensure_loaded?(CityOfBrusselsCouncil),
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
        %{note: "Issue 150: retry with the City of Brussels agenda normalizer"},
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
