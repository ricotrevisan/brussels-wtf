defmodule BrusselsWtf.CoverageStatus do
  @moduledoc "Bounded, public coverage projection. No review text, identities or transport errors are exposed."

  def snapshot(today) do
    first = Date.add(today, -90)
    last = Date.add(today, 30)

    communes =
      query(
        """
        SELECT c.slug, c.name, c.index_url,
          (SELECT max(o.observed_at) FROM retrieval_observations o
           JOIN source_locators l ON l.id=o.source_locator_id JOIN poll_runs p ON p.id=o.poll_run_id
           WHERE l.commune_id=c.id AND l.role='index' AND p.kind <> 'backfill' AND p.scope='current') AS attempted_at,
          (SELECT max(o.observed_at) FROM retrieval_observations o
           JOIN source_locators l ON l.id=o.source_locator_id JOIN poll_runs p ON p.id=o.poll_run_id
           WHERE l.commune_id=c.id AND l.role='index' AND p.kind <> 'backfill' AND p.scope='current'
           AND o.status IN ('success','unchanged')) AS checked_at
        FROM communes c WHERE c.slug IN ('ixelles','uccle','forest','city-of-brussels') ORDER BY c.slug
        """,
        []
      )

    meetings =
      query(
        """
        SELECT c.slug, l.meeting_identifier, l.scheduled_on,
          bool_or(l.role IN ('minutes','register')) AS final_source_seen,
          bool_or(mp.publication_status='published') AS published,
          max(mp.revision_published_at) AS published_at,
          max((SELECT count(*) FROM agenda_items i WHERE i.council_meeting_id=m.id AND i."published?" AND mp.publication_status='published')) AS selected_items,
          max((SELECT count(*) FROM agenda_items i WHERE i.council_meeting_id=m.id AND i.current_source_version_id IS NOT NULL AND NOT i."published?")) AS omitted_normalized_items,
          bool_or(EXISTS(SELECT 1 FROM source_records s JOIN source_versions v ON v.source_record_id=s.id WHERE s.commune_id=c.id AND s.origin_url=l.url)) AS downloaded,
          bool_or(EXISTS(
            SELECT 1 FROM source_records s
            CROSS JOIN LATERAL (SELECT v.sha256 FROM source_versions v WHERE v.source_record_id=s.id ORDER BY v.first_retrieved_at DESC,v.id DESC LIMIT 1) latest
            WHERE s.commune_id=c.id AND s.origin_url=l.url AND NOT EXISTS (
              SELECT 1 FROM publication_revisions pr JOIN coverage_runs cr ON cr.id=pr.canonical_run_id
              WHERE pr.id=mp.current_revision_id AND jsonb_path_exists(cr.input, '$.**.source_sha256 ? (@ == $sha)', jsonb_build_object('sha',latest.sha256))
            ))) AS source_update_pending,
          bool_or(COALESCE((SELECT o.status IN ('failure','disappeared') FROM retrieval_observations o JOIN poll_runs p ON p.id=o.poll_run_id WHERE o.source_locator_id=l.id AND p.kind <> 'backfill' ORDER BY o.observed_at DESC,o.id DESC LIMIT 1),false)) AS acquisition_failed,
          bool_or(EXISTS(SELECT 1 FROM review_cases r LEFT JOIN source_records s ON s.id=r.source_record_id
            WHERE r.status='open' AND r.commune_id=c.id AND (s.origin_url=l.url OR r.affected_record_id=m.id OR r.affected_record_id=mp.id))) AS review_pending
        FROM source_locators l JOIN communes c ON c.id=l.commune_id
        LEFT JOIN council_meetings m ON m.commune_id=c.id AND m.municipal_identifier=l.meeting_identifier
        LEFT JOIN meeting_pages mp ON mp.council_meeting_id=m.id
        WHERE l.scheduled_on BETWEEN $1 AND $2 AND l.role NOT IN ('index','mandate_declaration')
          AND c.slug IN ('ixelles','uccle','forest','city-of-brussels')
        GROUP BY c.slug,l.meeting_identifier,l.scheduled_on
        ORDER BY l.scheduled_on DESC,c.slug,l.meeting_identifier LIMIT 200
        """,
        [first, last]
      )

    %{first: first, last: last, communes: communes, meetings: meetings}
  end

  defp query(sql, params) do
    %{columns: columns, rows: rows} = Ecto.Adapters.SQL.query!(BrusselsWtf.Repo, sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end
end
