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
          max(mp.revision_published_at) AS published_at
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
