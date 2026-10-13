# Add recorded vote tallies to the four sealed-corpus decision pages (issue 127).
#
# Production generates coverage in paid mode, and recorded corrections refuse that mode.
# Run this in a separate `eval` VM with recorded generation (Repo and archive only, no
# Oban or web server), never through `rpc`, so the running release is not changed:
#
#   docker exec \
#     -e COVERAGE_GENERATION_MODE=recorded -e COVERAGE_PROCESSOR=recorded \
#     -e COVERAGE_MONTHLY_BUDGET_CENTS= -e BACKFILL_GENERATION_ENABLED=false \
#     "$APP_CONTAINER" /app/bin/brussels_wtf eval \
#     'BrusselsWtf.Release.run_ops(Application.app_dir(:brussels_wtf, "priv/ops/backfill_vote_tallies_20261013.exs"))'
#
# Default: read-only preflight. Apply with the exact revision IDs printed by the preflight:
#
#   BrusselsWtf.Release.run_ops(path, apply?: true, actor_id: "rico",
#     expected_revisions: %{"forest/2025-04-22" => "<uuid>", ...})
#
# Per page it re-normalizes the hash-pinned accepted text (backfill: no automatic
# publication), checks the recorded bundle in FR/NL/EN against the sealed manifest, and
# publishes one dated factual revision through Publication.recorded_factual_correction!/4.
# Summaries and dispositions are unchanged; only the cited vote tallies are added.
operator_options = binding()

alias BrusselsWtf.{Council, Ingestion, Review}
alias BrusselsWtf.Corpus.Manifest
alias BrusselsWtf.Council.{Publication, PublicationScope}

all_pages = [
  {"ixelles", "267", "ixelles-267"},
  {"uccle", "2025-06-26", "uccle-2025-06-26"},
  {"forest", "2026-03-24", "forest-2026-03-24"},
  {"forest", "2025-04-22", "forest-2025-04-22"}
]

# Optional `only: ["forest/2025-04-22"]` narrows the run to named pages.
pages =
  case Keyword.get(operator_options, :only) do
    nil -> all_pages
    only -> Enum.filter(all_pages, fn {c, id, _key} -> "#{c}/#{id}" in only end)
  end

notes = %{
  "fr" => "Ajout du décompte des votes cité dans le procès-verbal officiel.",
  "nl" => "Stemmingsresultaat uit het officiële proces-verbaal toegevoegd.",
  "en" => "Added the vote tally cited in the official minutes."
}

unless Council.GenerationControl.mode() == :recorded,
  do: raise("vote tally backfill requires recorded generation mode in this eval VM")

votes_of = fn input ->
  input["items"]
  |> Enum.filter(&(&1["procedural_state"] == "decision"))
  |> Map.new(fn item ->
    vote = Enum.find_value(item["claims"], &(&1["kind"] == "decision" && &1["vote"]))
    {item["key"], vote && {vote["for"], vote["against"], vote["abstentions"]}}
  end)
end

expected_votes = fn contract ->
  contract["items"]
  |> Enum.filter(&(&1["state"] == "decision"))
  |> Map.new(fn item ->
    {:ok, counts} = Council.VoteTally.parse(item["decision"]["vote"]["excerpt"])
    {item["key"], {counts.for, counts.against, counts.abstentions}}
  end)
end

plan =
  Enum.map(pages, fn {commune, municipal_id, contract_key} ->
    contract = Manifest.meeting!(contract_key)
    [source] = contract["sources"]
    {:ok, page} = Council.get_published_meeting_page(commune, municipal_id)
    meeting = Publication.load_meeting(page.council_meeting_id)
    page = meeting.meeting_page

    if page.publication_status != :published or page.withdrawn_at,
      do: raise("#{commune}/#{municipal_id} is not published")

    previous = Ash.load!(page.current_revision, :canonical_run)
    {scoped, _input} = PublicationScope.restore!(meeting, previous.canonical_run.input)

    unless MapSet.new(scoped.agenda_items, & &1.authoritative_identifier) ==
             MapSet.new(contract["items"], & &1["key"]),
           do: raise("#{commune}/#{municipal_id} scope differs from the sealed contract")

    [version_id] = scoped.agenda_items |> Enum.map(& &1.current_source_version_id) |> Enum.uniq()

    version =
      Ingestion.get_source_version!(version_id) |> Ash.load!([:source_record, :processing_runs])

    unless version.sha256 == source["sha256"] and version.source_record.origin_url == source["url"],
      do: raise("#{commune}/#{municipal_id} evidence source differs from the sealed contract")

    run =
      version.processing_runs
      |> Enum.filter(
        &(&1.status == :succeeded and &1.processor_role == :native_extraction and
            &1.quality_measurements["accepted"])
      )
      |> Enum.max_by(& &1.inserted_at, DateTime, fn -> nil end)

    if is_nil(run), do: raise("#{commune}/#{municipal_id} has no accepted native extraction")

    expected = expected_votes.(contract)
    published = votes_of.(previous.canonical_run.input)

    %{
      path: "#{commune}/#{municipal_id}",
      page_id: page.id,
      meeting_id: meeting.id,
      current_revision_id: previous.id,
      source_url: source["url"],
      source_sha256: version.sha256,
      processing_run_id: run.id,
      expected_votes: expected,
      published_votes: published,
      done?: published == expected
    }
  end)

IO.inspect(
  %{
    manifest_sha256: Manifest.digest(),
    normalization_contract: BrusselsWtf.Processors.normalization_contract(),
    pages: Enum.map(plan, &Map.drop(&1, [:page_id, :meeting_id]))
  },
  label: "Vote tally backfill preflight",
  limit: :infinity
)

if Keyword.get(operator_options, :apply?, false) != true do
  IO.puts("READ ONLY — no page was changed. Pass apply?: true with expected_revisions.")
else
  actor_id = Keyword.fetch!(operator_options, :actor_id)
  expected_revisions = Keyword.fetch!(operator_options, :expected_revisions)

  configured_actor =
    Application.fetch_env!(:brussels_wtf, :review_auth) |> Keyword.fetch!(:actor_id)

  unless actor_id == configured_actor,
    do: raise("Operator actor does not match the configured reviewer")

  actor = %Review.Actor{id: actor_id, role: :reviewer}

  for entry <- plan do
    if entry.done? do
      IO.inspect(%{page: entry.path, revision_id: entry.current_revision_id},
        label: "Vote tallies already published"
      )
    else
      expected_id = Map.fetch!(expected_revisions, entry.path)

      unless expected_id == entry.current_revision_id,
        do: raise("#{entry.path}: stale expected revision")

      # Appends a vote-bearing interpretation; backfill never enqueues publication.
      :ok = Ingestion.Pipeline.normalize(entry.processing_run_id, entry.source_url, 1, 3, :backfill)

      updated = Publication.load_meeting(entry.meeting_id)
      previous = Ash.load!(updated.meeting_page.current_revision, :canonical_run)
      {_scoped, input} = PublicationScope.restore!(updated, previous.canonical_run.input)

      unless votes_of.(input) == entry.expected_votes,
        do: raise("#{entry.path}: normalized votes differ from the sealed contract")

      for locale <- ~w(fr nl en), do: {:ok, _bundle} = Manifest.recorded_bundle(input, locale)

      revision = Publication.recorded_factual_correction!(entry.page_id, expected_id, notes, actor)

      IO.inspect(
        %{
          page: entry.path,
          previous_revision_id: revision.previous_revision_id,
          current_revision_id: revision.id,
          revision_kind: revision.revision_kind,
          publication_input_hash: revision.publication_input_hash
        },
        label: "Vote tallies published"
      )
    end
  end
end
