# Backfill for issue 146: close publication cases left open by an earlier publication.
# Run only through an authenticated operator session on the deployed release.
# Default is read-only: it lists the candidates and what stays open.
#   Code.eval_file(Application.app_dir(:brussels_wtf, "priv/ops/resolve_stale_publication_cases_20261103.exs"))
# Applying requires the exact ids from that listing, so an unreviewed case cannot close:
#   Code.eval_string(File.read!(path), [apply?: true, expected_case_ids: ["..."]])
#
# A case is stale only when its page is published and not withdrawn, and it was opened
# before the current revision. A case opened after that revision is a live signal and
# stays open. The script enqueues nothing and publishes nothing. It uses the same
# audited domain path as a publication.
options = Map.new(binding())
apply? = Map.get(options, :apply?, false)
expected_case_ids = Map.get(options, :expected_case_ids)

if apply? and not is_list(expected_case_ids) do
  raise "expected_case_ids is required to apply"
end

load_cases = fn lock_clause ->
  %{columns: columns, rows: rows} =
    BrusselsWtf.Repo.query!(
      """
      SELECT r.id::text AS id, c.slug AS commune, m.municipal_identifier AS meeting,
        r.inserted_at AS opened_at, mp.id::text AS page_id,
        mp.current_revision_id::text AS revision_id, mp.publication_input_hash AS input_hash,
        mp.revision_published_at AS revision_published_at,
        CASE
          WHEN mp.id IS NULL THEN 'page_not_found'
          WHEN mp.publication_status <> 'published' OR mp.withdrawn_at IS NOT NULL
            OR pr.id IS NULL THEN 'page_not_published'
          WHEN r.inserted_at >= mp.revision_published_at THEN 'opened_after_current_revision'
        END AS keep_open_reason
      FROM review_cases r
      LEFT JOIN meeting_pages mp ON mp.id = r.affected_record_id
      LEFT JOIN publication_revisions pr
        ON pr.id = mp.current_revision_id AND pr.meeting_page_id = mp.id
      LEFT JOIN council_meetings m ON m.id = mp.council_meeting_id
      LEFT JOIN communes c ON c.id = m.commune_id
      WHERE r.kind = 'publication' AND r.status = 'open'
      ORDER BY r.inserted_at, r.id
      #{lock_clause}
      """,
      []
    )

  Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
end

report = fn cases, read_only ->
  {left_open, stale} = Enum.split_with(cases, & &1["keep_open_reason"])

  IO.inspect(
    %{
      generate: "issue-146-stale-publication-cases",
      read_only: read_only,
      stale:
        Enum.map(
          stale,
          &Map.take(&1, ~w(id commune meeting opened_at revision_id revision_published_at))
        ),
      left_open: Enum.map(left_open, &Map.take(&1, ~w(id commune meeting keep_open_reason)))
    },
    limit: :infinity,
    printable_limit: :infinity
  )

  {stale, left_open}
end

summary = fn stale, left_open, applied, resolved ->
  %{
    applied: applied,
    stale_case_ids: Enum.map(stale, & &1["id"]),
    resolved_case_ids: resolved,
    left_open: Enum.map(left_open, &%{id: &1["id"], reason: &1["keep_open_reason"]})
  }
end

if apply? do
  {:ok, result} =
    BrusselsWtf.Repo.transaction(fn ->
      {stale, left_open} = report.(load_cases.("FOR UPDATE OF r"), false)
      stale_ids = Enum.map(stale, & &1["id"])

      if Enum.sort(stale_ids) != Enum.sort(expected_case_ids) do
        raise "expected_case_ids does not match the current candidates: #{inspect(stale_ids)}"
      end

      notifications =
        stale
        |> Enum.group_by(&{&1["page_id"], &1["revision_id"], &1["input_hash"]}, & &1["id"])
        |> Enum.flat_map(fn {{page_id, revision_id, input_hash}, case_ids} ->
          BrusselsWtf.Review.resolve_publication_cases_for_revision!(
            page_id,
            revision_id,
            input_hash,
            case_ids: case_ids,
            trigger: :backfill
          )
        end)

      {summary.(stale, left_open, true, stale_ids), notifications}
    end)

  {outcome, notifications} = result
  Ash.Notifier.notify(notifications)
  IO.puts("resolved #{length(outcome.resolved_case_ids)} stale publication cases")
  outcome
else
  {stale, left_open} = report.(load_cases.(""), true)
  IO.puts("read-only: no case was changed")
  summary.(stale, left_open, false, [])
end
