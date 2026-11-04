defmodule BrusselsWtf.CoverageStatus do
  @moduledoc "Bounded, public coverage projection. No review text, identities or transport errors are exposed."

  # Listing pages are how a commune's documents are found. They are not documents a
  # revision could cite, so counting them would report permanent pending work.
  @navigation_roles "('item_listing','document_listing')"

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
          COALESCE(bool_or(mp.publication_status='published'),false) AS published,
          max(mp.revision_published_at) AS published_at,
          max((SELECT count(*) FROM agenda_items i WHERE i.council_meeting_id=m.id AND i."published?" AND mp.publication_status='published')) AS selected_items,
          max((SELECT count(*) FROM agenda_items i WHERE i.council_meeting_id=m.id AND i.current_source_version_id IS NOT NULL AND NOT i."published?")) AS omitted_normalized_items,
          bool_or(d.source_record_id IS NOT NULL) AS downloaded,
          bool_or(d.source_record_id IS NOT NULL AND NOT d.latest_cited) AS source_update_pending,
          bool_or(COALESCE((SELECT o.status IN ('failure','disappeared') FROM retrieval_observations o JOIN poll_runs p ON p.id=o.poll_run_id WHERE o.source_locator_id=l.id AND p.kind <> 'backfill' ORDER BY o.observed_at DESC,o.id DESC LIMIT 1),false)) AS acquisition_failed,
          count(*) FILTER (WHERE d.source_record_id IS NOT NULL AND l.role NOT IN #{@navigation_roles}) AS retained_documents,
          count(*) FILTER (WHERE d.any_version_cited AND l.role NOT IN #{@navigation_roles}) AS cited_documents,
          count(*) FILTER (WHERE d.in_review AND l.role NOT IN #{@navigation_roles}) AS documents_in_review,
          count(*) FILTER (WHERE d.source_record_id IS NOT NULL AND NOT d.latest_cited AND NOT d.in_review AND l.role NOT IN #{@navigation_roles}) AS unaccounted_documents,
          EXISTS(SELECT 1 FROM review_cases r
            WHERE r.status='open' AND r.kind='publication' AND r.affected_record_id=mp.id) AS publication_review_pending,
          EXISTS(SELECT 1 FROM review_cases r
            WHERE r.status='open' AND r.kind IN ('acquisition','extraction','normalization','evidence') AND r.affected_record_id IN (m.id, mp.id)) AS meeting_review_pending
        FROM source_locators l JOIN communes c ON c.id=l.commune_id
        LEFT JOIN council_meetings m ON m.commune_id=c.id AND m.municipal_identifier=l.meeting_identifier
        LEFT JOIN meeting_pages mp ON mp.council_meeting_id=m.id
        LEFT JOIN LATERAL (
          SELECT s.id AS source_record_id,
            EXISTS(
              SELECT 1 FROM publication_revisions pr JOIN coverage_runs cr ON cr.id=pr.canonical_run_id
              WHERE pr.id=mp.current_revision_id AND jsonb_path_exists(cr.input, '$.**.source_sha256 ? (@ == $sha)', jsonb_build_object('sha',latest.sha256))
            ) AS latest_cited,
            EXISTS(
              SELECT 1 FROM publication_revisions pr JOIN coverage_runs cr ON cr.id=pr.canonical_run_id
              JOIN source_versions cited ON cited.source_record_id=s.id
              WHERE pr.id=mp.current_revision_id AND jsonb_path_exists(cr.input, '$.**.source_sha256 ? (@ == $sha)', jsonb_build_object('sha',cited.sha256))
            ) AS any_version_cited,
            EXISTS(
              SELECT 1 FROM review_cases r
              WHERE r.source_record_id=s.id AND r.status='open' AND r.kind IN ('acquisition','extraction','normalization','evidence')
            ) AS in_review
          FROM source_records s
          CROSS JOIN LATERAL (SELECT v.sha256 FROM source_versions v WHERE v.source_record_id=s.id ORDER BY v.first_retrieved_at DESC,v.id DESC LIMIT 1) latest
          WHERE s.commune_id=c.id AND s.origin_url=l.url
          LIMIT 1
        ) d ON true
        WHERE l.scheduled_on BETWEEN $1 AND $2 AND l.role NOT IN ('index','mandate_declaration')
          AND c.slug IN ('ixelles','uccle','forest','city-of-brussels')
        GROUP BY c.slug,l.meeting_identifier,l.scheduled_on,m.id,mp.id
        ORDER BY l.scheduled_on DESC,c.slug,l.meeting_identifier LIMIT 200
        """,
        [first, last]
      )

    %{first: first, last: last, communes: communes, meetings: meetings}
  end

  @doc """
  What this meeting's reader must be told, most specific first. Empty only when no
  known review, retrieval failure or unreflected retained document exists; it is not
  a claim that the coverage is complete.
  """
  def notices(meeting) do
    [
      meeting["publication_review_pending"] && :publication_check_pending,
      meeting["meeting_review_pending"] && :meeting_review_pending,
      (not meeting["published"] and meeting["documents_in_review"] > 0) &&
        :document_review_pending,
      meeting["acquisition_failed"] && :acquisition_failed,
      meeting["unaccounted_documents"] > 0 && :processing_pending
    ]
    |> Enum.filter(& &1)
  end

  defp query(sql, params) do
    %{columns: columns, rows: rows} = Ecto.Adapters.SQL.query!(BrusselsWtf.Repo, sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end
end
