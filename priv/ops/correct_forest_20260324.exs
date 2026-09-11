# Run only through an authenticated operator session for issue 77.
# Code.eval_file(Application.app_dir(:brussels_wtf, "priv/ops/correct_forest_20260324.exs"))
# Default: read-only. Apply requires explicit Code.eval_string/3 bindings:
# apply?: true, expected_revision_id: <preflight UUID>, actor_id: <reviewer ID>
# Bindings do not change the running release's environment or generation policy.
operator_options = binding()

alias BrusselsWtf.{Council, Ingestion, Review}
alias BrusselsWtf.Corpus.Manifest
alias BrusselsWtf.Council.{Publication, PublicationScope}

source_hash = "6e31a35822196823ecba87cbd4b185ad7eb92e4c99cf6c86f441867a86086d26"

source_url =
  "https://forest.brussels/sites/default/files/publications/registre/2026-03/PV%20%20conseil%20communal%20-%20gemeenteraad%2024032026.pdf"

item_keys = ~w(forest-2026-03-24-9 forest-2026-03-24-15 forest-2026-03-24-20)

notes = %{
  "fr" =>
    "L’étiquette « approuvée » des points 9 et 15 était trop générale : le conseil a approuvé une prise de connaissance des décisions du collège, non les marchés eux-mêmes.",
  "nl" =>
    "Het label ‘goedgekeurd’ bij punten 9 en 15 was te algemeen: de raad keurde een kennisneming van collegebesluiten goed, niet de opdrachten zelf.",
  "en" =>
    "The Approved label on items 9 and 15 was too broad: the council approved acknowledgement of executive decisions, not the underlying contracts."
}

{:ok, page} = Council.get_published_meeting_page("forest", "2026-03-24")
if page.publication_status != :published, do: raise("Forest page is not published")
meeting = Publication.load_meeting(page.council_meeting_id)
previous = Ash.load!(meeting.meeting_page.current_revision, :canonical_run)
{scoped, old_input} = PublicationScope.restore!(meeting, previous.canonical_run.input)

unless MapSet.new(Enum.map(scoped.agenda_items, & &1.authoritative_identifier)) ==
         MapSet.new(item_keys),
       do: raise("Forest publication scope differs from the audited three items")

[version_id] = scoped.agenda_items |> Enum.map(& &1.current_source_version_id) |> Enum.uniq()

version =
  Ingestion.get_source_version!(version_id) |> Ash.load!([:source_record, :processing_runs])

unless version.sha256 == source_hash and version.source_record.origin_url == source_url,
  do: raise("Forest evidence source differs from the audited version")

run =
  version.processing_runs
  |> Enum.filter(
    &(&1.status == :succeeded and &1.processor_role == :native_extraction and
        &1.quality_measurements["accepted"])
  )
  |> Enum.max_by(& &1.inserted_at, DateTime, fn -> nil end)

if is_nil(run), do: raise("No accepted native extraction exists for the audited source")

preflight = %{
  meeting_page_id: page.id,
  current_revision_id: previous.id,
  source_sha256: source_hash,
  processing_run_id: run.id,
  normalization_contract: BrusselsWtf.Processors.normalization_contract(),
  manifest_sha256: Manifest.digest(),
  normalized_outcomes: Map.new(old_input["items"], &{&1["key"], &1["outcome"]}),
  published_outcomes: Map.new(previous.canonical_run.input["items"], &{&1["key"], &1["outcome"]})
}

if Keyword.get(operator_options, :apply?, false) != true do
  IO.inspect(preflight, label: "READ ONLY — Forest correction preflight")
else
  expected_id = Keyword.fetch!(operator_options, :expected_revision_id)
  actor_id = Keyword.fetch!(operator_options, :actor_id)

  configured_actor =
    Application.fetch_env!(:brussels_wtf, :review_auth) |> Keyword.fetch!(:actor_id)

  unless actor_id == configured_actor,
    do: raise("Operator actor does not match the configured reviewer")

  actor = %Review.Actor{id: actor_id, role: :reviewer}

  unless Council.GenerationControl.mode() == :recorded,
    do: raise("Forest correction requires recorded generation mode")

  if previous.id == expected_id do
    review_case =
      Review.open_review_case!(%{
        kind: :evidence,
        commune_id: meeting.commune_id,
        affected_record_id: page.id,
        affected_record_type: "meeting_page",
        source_record_id: version.source_record_id,
        source_version_id: version.id,
        processing_generation: "issue-77:forest-outcomes:" <> Manifest.digest(),
        summary: "Forest items 9 and 15: distinguish acknowledgement from contract approval",
        normalized_content: previous.canonical_run.input,
        related_evidence: %{
          "citation_url" => source_url,
          "source_sha256" => source_hash,
          "locations" => ["point 9, pages 30–31/92", "point 15, pages 45–46/92"],
          "processing_run_id" => run.id,
          "normalization_contract" => BrusselsWtf.Processors.normalization_contract(),
          "issue_url" => "https://github.com/RicoTrevisan/brussels-wtf/issues/77"
        }
      })

    # This validates the private accepted text artifact and appends interpretations.
    # Backfill normalization deliberately does not enqueue automatic publication.
    :ok = Ingestion.Pipeline.normalize(run.id, source_url, 1, 3, :backfill)
    updated = Publication.load_meeting(meeting.id)
    {_scoped, input} = PublicationScope.restore!(updated, previous.canonical_run.input)

    for locale <- ~w(fr nl en), do: {:ok, _bundle} = Manifest.recorded_bundle(input, locale)
    outcomes = Map.new(input["items"], &{&1["key"], &1["outcome"]})

    unless outcomes == %{
             "forest-2026-03-24-9" => "other",
             "forest-2026-03-24-15" => "other",
             "forest-2026-03-24-20" => "approved"
           },
           do: raise("Recorded normalization does not match the audited correction")

    if review_case.status == :open do
      Review.correct_review_case!(review_case, %{note: notes["en"], corrected_content: input},
        actor: actor
      )
    end
  end

  # This also rejects a stale expected revision, or returns the exact prior result
  # on replay. Authorization does not attach human-reviewed provenance.
  revision = Publication.recorded_factual_correction!(page.id, expected_id, notes, actor)

  IO.inspect(
    %{
      meeting_page_id: page.id,
      previous_revision_id: revision.previous_revision_id,
      current_revision_id: revision.id,
      revision_kind: revision.revision_kind,
      publication_input_hash: revision.publication_input_hash,
      provenance: revision.publication_metadata["provenance"]
    },
    label: "Forest correction published or already applied"
  )
end
