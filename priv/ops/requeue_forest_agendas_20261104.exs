# Retry stale Forest agenda normalization for issue 149.
# Run only through an authenticated operator session on the deployed release:
#   Code.eval_file(Application.app_dir(:brussels_wtf, "priv/ops/requeue_forest_agendas_20261104.exs"))
# Default is read-only: it previews each candidate with the deployed normalizer, in
# memory, and changes nothing. Applying requires explicit bindings:
#   Code.eval_string(File.read!(path), apply?: true, limit: 2, actor_id: "<reviewer id>")
#
# Applying uses the audited review retry: a new processing generation re-extracts the
# retained bytes, resolves the stale case, normalizes, and queues automatic publication.
# It selects only agendas of meetings from 2026-09-01 and never a recorded-corpus
# meeting, whose sealed page must stay byte-identical. See docs/operations/forest-agendas.md.
options = Map.new(binding())
apply? = Map.get(options, :apply?, false)
limit = Map.get(options, :limit)
actor_id = Map.get(options, :actor_id)
first_meeting = ~D[2026-09-01]
agenda_roles = ~w(agenda complementary_agenda)

alias BrusselsWtf.Corpus.Manifest
alias BrusselsWtf.Ingestion.Pipeline
alias BrusselsWtf.{Ingestion, Processors, Repo, Review}

if apply? do
  unless is_integer(limit), do: raise("limit must be an integer")
  if limit < 1, do: raise("limit must be positive")
  if limit > 25, do: raise("refusing to requeue more than 25 runs without a new decision")

  unless is_binary(actor_id) and String.trim(actor_id) != "",
    do: raise("actor_id must name the reviewer")
end

%{rows: rows} =
  Repo.query!("""
  SELECT rc.id::text, rc.related_evidence->>'processing_run_id', s.origin_url, l.role,
         l.meeting_identifier, l.scheduled_on, v.sha256,
         v.id = (SELECT latest.id FROM source_versions latest
                 WHERE latest.source_record_id = s.id
                 ORDER BY latest.first_retrieved_at DESC, latest.id DESC LIMIT 1)
  FROM review_cases rc
  JOIN communes c ON c.id = rc.commune_id
  JOIN source_records s ON s.id = rc.source_record_id
  JOIN source_versions v ON v.id = rc.source_version_id
  LEFT JOIN source_locators l ON l.url = s.origin_url AND l.commune_id = s.commune_id
  WHERE c.slug = 'forest'
    AND rc.kind = 'normalization'
    AND rc.status = 'open'
    AND rc.disposition = 'open'
    AND rc.diagnostics->>'classification' = 'processor_unavailable'
  ORDER BY l.scheduled_on ASC NULLS FIRST, rc.id ASC
  """)

summarize = fn normalized ->
  items = normalized["items"]
  proposals = Enum.count(items, &Map.has_key?(&1, "proposals"))

  %{
    agenda_kind: normalized["agenda"]["kind"],
    items: length(items),
    proposals: proposals,
    non_votable: length(items) - proposals
  }
end

assess = fn [case_id, run_id, origin_url, role, identifier, scheduled_on, sha256, latest?] ->
  base = %{
    case_id: case_id,
    run_id: run_id,
    role: role,
    meeting_identifier: identifier,
    sha256: sha256,
    origin_url: origin_url
  }

  exclusion =
    cond do
      role not in agenda_roles ->
        "not_an_agenda"

      is_nil(scheduled_on) or Date.compare(scheduled_on, first_meeting) == :lt ->
        "before_2026_09_01"

      not latest? ->
        "superseded_source_version"

      Manifest.meeting_by_identity("forest", identifier) ->
        "recorded_corpus_meeting"

      true ->
        nil
    end

  if exclusion do
    Map.merge(base, %{outcome: :excluded, reason: exclusion})
  else
    run = Ingestion.get_processing_run!(run_id)

    if run.status == :succeeded and run.quality_measurements["accepted"] do
      case Processors.normalize(Pipeline.normalization_input(run)) do
        {:ok, normalized} ->
          Map.merge(base, %{outcome: :ready, preview: summarize.(normalized)})

        {:error, {:normalization_ambiguity, details}} ->
          Map.merge(base, %{outcome: :excluded, reason: "preview_ambiguous", details: details})

        {:error, reason} ->
          Map.merge(base, %{outcome: :excluded, reason: "preview_failed", details: reason})
      end
    else
      Map.merge(base, %{outcome: :excluded, reason: "run_not_accepted"})
    end
  end
end

assessed = Enum.map(rows, assess)
ready = Enum.filter(assessed, &(&1.outcome == :ready))
{historical, listed} = Enum.split_with(assessed, &(Map.get(&1, :reason) == "before_2026_09_01"))

%{rows: budget} =
  Repo.query!("""
  SELECT period_start::text, hard_limit_cents, reserved_cents, spent_cents, poisoned_at IS NOT NULL
  FROM coverage_budgets
  WHERE period_start = date_trunc('month', now() AT TIME ZONE 'UTC')::date
  """)

IO.inspect(
  %{
    generate: "issue-149-forest-agenda-requeue",
    read_only: not apply?,
    normalization_contract: Processors.normalization_contract(),
    coverage_generation_mode: Application.fetch_env!(:brussels_wtf, :coverage_generation).mode,
    current_month_budget: budget,
    ready_count: length(ready),
    excluded_count: length(assessed) - length(ready),
    untouched_before_2026_09_01: length(historical),
    candidates: listed
  },
  limit: :infinity,
  printable_limit: :infinity
)

if apply? do
  actor = %Review.Actor{id: actor_id, role: :reviewer}

  results =
    ready
    |> Enum.take(limit)
    |> Enum.map(fn %{case_id: case_id, meeting_identifier: identifier} ->
      review_case = Review.get_review_case!(case_id, actor: actor)

      outcome =
        case Review.retry_review_case(
               review_case,
               %{note: "Issue 149: retry with the deployed Forest agenda normalizer."},
               actor: actor
             ) do
          {:ok, _case} -> :retry_requested
          {:error, error} -> {:error, Exception.message(error)}
        end

      %{case_id: case_id, meeting_identifier: identifier, outcome: outcome}
    end)

  IO.inspect(%{applied: length(results), results: results}, limit: :infinity)
else
  IO.puts("read-only: nothing was requeued. Pass apply?: true, limit:, and actor_id: to apply.")
end

:ok
