# Read-only scorecard for issue 146: does the agenda-to-page loop run without a person?
# Run through an authenticated operator session on the deployed release:
#   Code.eval_file(Application.app_dir(:brussels_wtf, "priv/ops/agenda_to_page_scorecard.exs"))
# Prints one JSON line per commune's latest meeting with a retained agenda. Pass
#   Code.eval_string(File.read!(path), [per_commune: 3])
# to include earlier meetings. It runs in a read-only transaction that always rolls back.
#
# Fields
# - agenda_retained_at: first retrieval of any version of the agenda or complementary agenda.
# - first_published_at: first publication revision. lag_seconds is the gap from retention
#   and can be negative when the page was published from another source before an agenda
#   was retained. waiting_seconds replaces it while nothing has published.
# - hand_queued: `no` only when the publishing job was inserted inside a normalization job
#   of this meeting, which is how the pipeline queues it. `yes` is a coverage batch or a job
#   with no such parent, even if its args say `automatic`. `unknown` means the job is not
#   retained: the answer is never guessed. `not_published` means there is nothing to judge.
options = Map.new(binding())
per_commune = Map.get(options, :per_commune, 1)

unless is_integer(per_commune) and per_commune in 1..12 do
  raise "per_commune must be between 1 and 12"
end

communes = ~w(city-of-brussels forest ixelles uccle)

sql = """
WITH agenda_meetings AS (
  SELECT c.id AS commune_id, c.slug, l.meeting_identifier, l.scheduled_on,
    min(v.first_retrieved_at) AS agenda_retained_at,
    count(DISTINCT v.id) AS agenda_versions
  FROM source_locators l
  JOIN communes c ON c.id = l.commune_id
  JOIN source_records s ON s.commune_id = c.id AND s.origin_url = l.url
  JOIN source_versions v ON v.source_record_id = s.id
  WHERE l.role IN ('agenda', 'complementary_agenda')
    AND c.slug = ANY($1) AND l.meeting_identifier IS NOT NULL AND l.scheduled_on IS NOT NULL
  GROUP BY c.id, c.slug, l.meeting_identifier, l.scheduled_on
), ranked AS (
  SELECT a.*, row_number() OVER (
    PARTITION BY a.slug ORDER BY a.scheduled_on DESC, a.meeting_identifier DESC
  ) AS position
  FROM agenda_meetings a
)
SELECT r.slug, r.meeting_identifier, r.scheduled_on, r.agenda_retained_at, r.agenda_versions,
  COALESCE(mp.publication_status = 'published', false) AS published,
  mp.withdrawn_at IS NOT NULL AS withdrawn,
  first_revision.published_at AS first_published_at,
  CASE WHEN mp.publication_status = 'published' THEN mp.revision_published_at END AS current_revision_published_at,
  EXTRACT(EPOCH FROM first_revision.published_at - r.agenda_retained_at)::bigint AS lag_seconds,
  CASE WHEN first_revision.published_at IS NULL
    THEN EXTRACT(EPOCH FROM timezone('UTC', now()) - r.agenda_retained_at)::bigint END AS waiting_seconds,
  COALESCE(items.normalized, 0) AS normalized_items,
  COALESCE(items.published, 0) AS published_items,
  COALESCE(items.normalized, 0) - COALESCE(items.published, 0) AS other_items,
  job.args->>'coverage_batch_id' AS coverage_batch_id,
  job.id AS publishing_job_id,
  parent.id AS normalization_job_id
FROM ranked r
LEFT JOIN council_meetings m
  ON m.commune_id = r.commune_id AND m.municipal_identifier = r.meeting_identifier
LEFT JOIN meeting_pages mp ON mp.council_meeting_id = m.id
LEFT JOIN LATERAL (
  SELECT min(pr.published_at) AS published_at
  FROM publication_revisions pr WHERE pr.meeting_page_id = mp.id
) first_revision ON true
LEFT JOIN LATERAL (
  SELECT count(*) FILTER (WHERE i.current_source_version_id IS NOT NULL) AS normalized,
    count(*) FILTER (
      WHERE i.current_source_version_id IS NOT NULL AND i."published?"
        AND mp.publication_status = 'published'
    ) AS published
  FROM agenda_items i WHERE i.council_meeting_id = m.id
) items ON true
LEFT JOIN LATERAL (
  SELECT j.id, j.args, j.inserted_at
  FROM oban_jobs j
  WHERE j.worker = 'BrusselsWtf.Workers.PublishMeeting'
    AND j.args->>'meeting_id' = m.id::text
    AND j.attempted_at <= first_revision.published_at
    AND j.completed_at >= first_revision.published_at
  ORDER BY j.inserted_at DESC, j.id DESC
  LIMIT 1
) job ON true
LEFT JOIN LATERAL (
  SELECT n.id
  FROM oban_jobs n
  JOIN processing_runs pr ON pr.id::text = n.args->>'processing_run_id'
  JOIN source_versions sv ON sv.id = pr.source_version_id
  JOIN source_records sr ON sr.id = sv.source_record_id
  WHERE n.worker = 'BrusselsWtf.Workers.NormalizeSource'
    AND sr.council_meeting_id = m.id
    AND n.attempted_at <= job.inserted_at
    AND n.completed_at >= job.inserted_at
  ORDER BY n.id DESC
  LIMIT 1
) parent ON true
WHERE r.position <= $2
ORDER BY r.slug, r.scheduled_on DESC, r.meeting_identifier DESC
"""

# Always rolled back, so the read-only setting cannot outlive this script in a caller's
# transaction, and a query that tried to write would fail rather than persist.
{:error, %{columns: columns, rows: rows}} =
  BrusselsWtf.Repo.transaction(fn ->
    BrusselsWtf.Repo.query!("SET TRANSACTION READ ONLY", [])
    BrusselsWtf.Repo.rollback(BrusselsWtf.Repo.query!(sql, [communes, per_commune]))
  end)

iso = fn
  nil -> nil
  %NaiveDateTime{} = value -> NaiveDateTime.to_iso8601(NaiveDateTime.truncate(value, :second))
  %DateTime{} = value -> DateTime.to_iso8601(DateTime.truncate(value, :second))
  %Date{} = value -> Date.to_iso8601(value)
end

classify = fn row ->
  cond do
    is_nil(row["first_published_at"]) -> {"not_published", "no_publication_revision"}
    is_nil(row["publishing_job_id"]) -> {"unknown", "publishing_job_not_found"}
    row["coverage_batch_id"] -> {"yes", "coverage_batch:#{row["coverage_batch_id"]}"}
    row["normalization_job_id"] ->
      {"no", "inserted_inside_normalization_job:#{row["normalization_job_id"]}"}
    true -> {"yes", "no_normalization_parent"}
  end
end

meetings =
  Enum.map(rows, fn values ->
    row = columns |> Enum.zip(values) |> Map.new()
    {hand_queued, evidence} = classify.(row)

    %{
      commune: row["slug"],
      status: "retained_agenda",
      meeting_identifier: row["meeting_identifier"],
      scheduled_on: iso.(row["scheduled_on"]),
      agenda_retained_at: iso.(row["agenda_retained_at"]),
      agenda_versions: row["agenda_versions"],
      published: row["published"],
      withdrawn: row["withdrawn"],
      first_published_at: iso.(row["first_published_at"]),
      current_revision_published_at: iso.(row["current_revision_published_at"]),
      lag_seconds: row["lag_seconds"],
      waiting_seconds: row["waiting_seconds"],
      hand_queued: hand_queued,
      hand_queued_evidence: evidence,
      normalized_items: row["normalized_items"],
      published_items: row["published_items"],
      other_items: row["other_items"]
    }
  end)

missing =
  for commune <- communes, not Enum.any?(meetings, &(&1.commune == commune)) do
    %{commune: commune, status: "no_retained_agenda", meeting_identifier: nil}
  end

scorecard = Enum.sort_by(meetings ++ missing, & &1.commune)
Enum.each(scorecard, &IO.puts(Jason.encode!(&1)))
scorecard
