# Requeue stalled normalization for issue 98.
# Run only through an authenticated operator session on the deployed release:
#   Code.eval_file(Application.app_dir(:brussels_wtf, "priv/ops/requeue_normalization_20260918.exs"))
# Default is read-only: it prints the candidate work and changes nothing.
# Applying requires explicit bindings, for example:
#   Code.eval_string(File.read!(path), [apply?: true, commune: "ixelles", role: "agenda", limit: 3])
# Bindings never change the running release's environment or generation policy.
#
# Before applying: pause the :normalize and :publish queues through the normal
# operational path, and confirm no deployment is mid-flight (a deploy changes the
# normalization contract and discards queued work). This script never touches Oban.
options = Map.new(binding())
apply? = Map.get(options, :apply?, false)
commune = Map.get(options, :commune, "ixelles")
role = Map.get(options, :role, "agenda")
limit = Map.get(options, :limit, 1)

if apply? and not is_integer(limit), do: raise("limit must be an integer")
if apply? and limit < 1, do: raise("limit must be positive")
if apply? and limit > 25, do: raise("refusing to requeue more than 25 runs without a new decision")

candidates_sql = """
SELECT DISTINCT ON (r.id) r.id, c.slug, l.role, s.origin_url, v.sha256
FROM processing_runs r
JOIN source_versions v ON v.id = r.source_version_id
JOIN source_records s ON s.id = v.source_record_id
JOIN communes c ON c.id = s.commune_id
LEFT JOIN source_locators l ON l.url = s.origin_url
WHERE r.processor_role = 'native_extraction'
  AND r.status = 'succeeded'
  AND coalesce((r.quality_measurements->>'accepted')::boolean, false)
  AND s.council_meeting_id IS NULL
  AND c.slug = $1
  AND ($2::text IS NULL OR l.role = $2)
ORDER BY r.id, v.inserted_at DESC
"""

%{rows: rows} =
  BrusselsWtf.Repo.query!(candidates_sql, [commune, if(role in [nil, ""], do: nil, else: role)])

preflight = %{
  generate: "issue-98-normalization-requeue",
  read_only: not apply?,
  commune: commune,
  role: role,
  normalization_contract: BrusselsWtf.Processors.normalization_contract(),
  candidate_count: length(rows),
  candidates: Enum.map(rows, fn [run_id, slug, loc_role, origin_url, sha256] ->
    %{run_id: run_id, commune: slug, role: loc_role, sha256: sha256, origin_url: origin_url}
  end)
}

IO.inspect(preflight, limit: :infinity, printable_limit: :infinity)

if apply? do
  chosen = Enum.take(rows, limit)

  # One case per (failure_kind, affected_record_id, processing_generation); the
  # generation key embeds the run id, so a rerun of the same run cannot duplicate it.
  results =
    Enum.map(chosen, fn [run_id, slug, loc_role, origin_url, _sha256] ->
      outcome = BrusselsWtf.Ingestion.Pipeline.normalize(run_id, origin_url, 1, 3, :backfill)
      IO.inspect(%{run_id: run_id, commune: slug, role: loc_role, outcome: outcome})
      {run_id, outcome}
    end)

  IO.inspect(%{applied: length(results), results: results})
else
  IO.puts("read-only: no normalization was requeued. Pass apply?: true to requeue.")
end
