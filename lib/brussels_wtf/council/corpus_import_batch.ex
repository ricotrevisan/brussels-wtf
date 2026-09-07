defmodule BrusselsWtf.Council.CorpusImportBatch do
  @moduledoc "One immutable, authenticated real-corpus source allowlist and its measurements."

  require Ash.Query

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "corpus_import_batches"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      public? false
      primary? true

      accept [
        :requester_id,
        :manifest_sha256,
        :meeting_keys,
        :expected_documents,
        :expected_bytes,
        :status,
        :metrics
      ]
    end

    update :mark_importing do
      public? false
      require_atomic? false
      accept [:started_at]
      validate attribute_equals(:status, :queued)
      change set_attribute(:status, :importing)
    end

    update :record_source do
      public? false
      require_atomic? false
      accept [:meeting_ids, :source_version_ids]
      validate fn changeset, _context -> __MODULE__.validate_source_transition(changeset) end
      change set_attribute(:status, :normalizing)
    end

    update :refresh_report do
      public? false
      require_atomic? false

      accept [
        :processing_run_ids,
        :coverage_run_ids,
        :review_case_ids,
        :meeting_page_ids,
        :metrics
      ]
    end

    update :mark_ready do
      public? false
      require_atomic? false

      accept [
        :processing_run_ids,
        :coverage_run_ids,
        :review_case_ids,
        :meeting_page_ids,
        :metrics
      ]

      validate fn changeset, _context -> __MODULE__.validate_ready(changeset) end
      change set_attribute(:status, :ready_for_coverage)
    end

    update :record_preparation do
      public? false
      require_atomic? false

      accept [
        :coverage_batch_id,
        :dossier_id,
        :dossier_link_ids,
        :content_reviewed_by,
        :content_reviewed_at
      ]

      validate attribute_equals(:status, :ready_for_coverage)
    end

    update :mark_completed do
      public? false
      require_atomic? false

      accept [
        :processing_run_ids,
        :coverage_run_ids,
        :review_case_ids,
        :meeting_page_ids,
        :metrics,
        :completed_at
      ]

      validate fn changeset, _context -> __MODULE__.validate_completed(changeset) end
      change set_attribute(:status, :completed)
    end

    update :block do
      public? false
      require_atomic? false
      validate fn changeset, _context -> __MODULE__.validate_block(changeset) end

      accept [
        :meeting_ids,
        :source_version_ids,
        :processing_run_ids,
        :coverage_run_ids,
        :review_case_ids,
        :meeting_page_ids,
        :metrics,
        :failure
      ]

      change set_attribute(:status, :blocked)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :requester_id, :string, allow_nil?: false, public?: true
    attribute :manifest_sha256, :string, allow_nil?: false, public?: true
    attribute :meeting_keys, {:array, :string}, allow_nil?: false, public?: true
    attribute :expected_documents, :integer, allow_nil?: false, public?: true
    attribute :expected_bytes, :integer, allow_nil?: false, public?: true
    attribute :meeting_ids, {:array, :uuid}, allow_nil?: false, public?: true, default: []
    attribute :source_version_ids, {:array, :uuid}, allow_nil?: false, public?: true, default: []
    attribute :processing_run_ids, {:array, :uuid}, allow_nil?: false, public?: true, default: []
    attribute :coverage_run_ids, {:array, :uuid}, allow_nil?: false, public?: true, default: []
    attribute :review_case_ids, {:array, :uuid}, allow_nil?: false, public?: true, default: []
    attribute :meeting_page_ids, {:array, :uuid}, allow_nil?: false, public?: true, default: []
    attribute :coverage_batch_id, :uuid, public?: true
    attribute :dossier_id, :uuid, public?: true
    attribute :dossier_link_ids, {:array, :uuid}, allow_nil?: false, public?: true, default: []
    attribute :content_reviewed_by, :string, public?: true
    attribute :content_reviewed_at, :utc_datetime_usec, public?: true
    attribute :metrics, :map, allow_nil?: false, public?: true, default: %{}
    attribute :failure, :string, public?: true
    attribute :started_at, :utc_datetime_usec, public?: true
    attribute :completed_at, :utc_datetime_usec, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :queued

      constraints one_of: [
                    :queued,
                    :importing,
                    :normalizing,
                    :ready_for_coverage,
                    :completed,
                    :blocked
                  ]
    end

    timestamps()
  end

  def validate_source_transition(changeset) do
    if changeset.data.status in [:importing, :normalizing],
      do: :ok,
      else: {:error, "source recording requires an open importing batch"}
  end

  def validate_block(changeset) do
    if changeset.data.status in [:queued, :importing, :normalizing, :ready_for_coverage, :blocked],
      do: :ok,
      else: {:error, "completed real-corpus batches are closed"}
  end

  def validate_ready(changeset) do
    batch = changeset.data
    metrics = Ash.Changeset.get_attribute(changeset, :metrics) || %{}
    review_case_ids = Ash.Changeset.get_attribute(changeset, :review_case_ids) || []

    valid? =
      batch.status == :normalizing and
        batch.manifest_sha256 == BrusselsWtf.Corpus.Manifest.digest() and
        length(batch.meeting_keys) == 8 and length(batch.meeting_ids) == 8 and
        length(batch.source_version_ids) == 9 and metrics["normalized_items"] == 24 and
        review_case_ids == [] and exact_normalized_contract?(batch) and exact_sources?(batch) and
        not open_related_cases?(batch, changeset)

    if valid?, do: :ok, else: {:error, "real corpus is not ready for coverage"}
  end

  def validate_completed(changeset) do
    metrics = Ash.Changeset.get_attribute(changeset, :metrics) || %{}
    review_case_ids = Ash.Changeset.get_attribute(changeset, :review_case_ids) || []
    meeting_page_ids = Ash.Changeset.get_attribute(changeset, :meeting_page_ids) || []

    valid? =
      changeset.data.status == :ready_for_coverage and
        length(meeting_page_ids) == 8 and metrics["pages_published"] == 8 and
        metrics["generation_calls"] == 24 and review_case_ids == [] and
        published_pages?(meeting_page_ids, changeset.data) and successful_runs?(changeset) and
        current_publications_match?(meeting_page_ids) and
        not open_related_cases?(changeset.data, changeset)

    if valid?, do: :ok, else: {:error, "real corpus publication is not complete"}
  end

  def current_publications_match?(page_ids) do
    Enum.all?(page_ids, fn id ->
      page =
        id
        |> BrusselsWtf.Council.get_meeting_page!()
        |> Ash.load!(current_revision: [:canonical_run, :nl_run, :en_run])

      revision = page.current_revision
      canonical = revision.canonical_run
      runs = [{"fr", canonical}, {"nl", revision.nl_run}, {"en", revision.en_run}]

      Enum.all?(runs, fn {locale, run} ->
        case BrusselsWtf.Corpus.Manifest.recorded_bundle(canonical.input, locale) do
          {:ok, expected} ->
            Map.take(run.output, ["page", "items"]) == Map.take(expected, ["page", "items"])

          {:error, _} ->
            false
        end
      end) and BrusselsWtf.Council.PublicationGate.evaluate(id, canonical.input_hash).ready?
    end)
  rescue
    _error -> false
  end

  defp exact_normalized_contract?(batch) do
    expected =
      BrusselsWtf.Corpus.Manifest.load!()["meetings"]
      |> Map.new(fn meeting ->
        {{meeting["commune"], meeting["municipal_identifier"]},
         MapSet.new(Enum.map(meeting["items"], & &1["key"]))}
      end)

    actual =
      Enum.map(batch.meeting_ids, fn id ->
        meeting =
          id
          |> BrusselsWtf.Council.get_meeting!()
          |> Ash.load!([:commune, :agenda_items])

        {{meeting.commune.slug, meeting.municipal_identifier},
         MapSet.new(Enum.map(meeting.agenda_items, & &1.authoritative_identifier))}
      end)
      |> Map.new()

    MapSet.new(Map.keys(actual)) == MapSet.new(Map.keys(expected)) and
      Enum.all?(expected, fn {identity, expected_items} ->
        MapSet.subset?(expected_items, Map.fetch!(actual, identity))
      end)
  rescue
    _error -> false
  end

  defp exact_sources?(batch) do
    meetings =
      BrusselsWtf.Corpus.Manifest.load!()["meetings"]
      |> Map.new(&{&1["key"], &1})

    expected =
      Enum.reduce(meetings, %{}, fn {_key, meeting}, result ->
        Enum.reduce(meeting["sources"], result, fn source, sources ->
          Map.put(sources, source["sha256"], {
            source["url"],
            {meeting["commune"], meeting["municipal_identifier"]}
          })
        end)
      end)

    actual =
      Enum.map(batch.source_version_ids, fn id ->
        version =
          id
          |> BrusselsWtf.Ingestion.get_source_version!()
          |> Ash.load!(source_record: [council_meeting: [:commune]])

        meeting = version.source_record.council_meeting

        {version.sha256,
         {
           version.source_record.origin_url,
           {meeting.commune.slug, meeting.municipal_identifier}
         }}
      end)
      |> Map.new()

    actual == expected
  rescue
    _error -> false
  end

  defp open_related_cases?(batch, changeset) do
    processing_run_ids = Ash.Changeset.get_attribute(changeset, :processing_run_ids) || []
    page_ids = Ash.Changeset.get_attribute(changeset, :meeting_page_ids) || []
    run_ids = Ash.Changeset.get_attribute(changeset, :coverage_run_ids) || []

    ids =
      batch.meeting_ids ++ batch.source_version_ids ++ processing_run_ids ++ page_ids ++ run_ids

    BrusselsWtf.Review.Case
    |> Ash.Query.filter(affected_record_id in ^ids and status == :open)
    |> Ash.exists?(domain: BrusselsWtf.Review, authorize?: false)
  end

  defp published_pages?(ids, batch) do
    expected_ids =
      batch.meeting_ids
      |> Enum.map(fn meeting_id ->
        meeting_id
        |> BrusselsWtf.Council.get_meeting!()
        |> Ash.load!(:meeting_page)
        |> Map.fetch!(:meeting_page)
        |> Map.fetch!(:id)
      end)
      |> MapSet.new()

    actual_ids = MapSet.new(ids)

    actual_ids == expected_ids and MapSet.size(actual_ids) == 8 and
      Enum.all?(ids, fn id ->
        BrusselsWtf.Council.get_meeting_page!(id).publication_status == :published
      end)
  rescue
    _error -> false
  end

  defp successful_runs?(changeset) do
    ids = Ash.Changeset.get_attribute(changeset, :coverage_run_ids) || []
    page_ids = MapSet.new(Ash.Changeset.get_attribute(changeset, :meeting_page_ids) || [])

    runs =
      Enum.map(ids, fn id ->
        Ash.get!(BrusselsWtf.Council.CoverageRun, id, domain: BrusselsWtf.Council)
      end)

    expected_run_ids =
      page_ids
      |> Enum.flat_map(fn page_id ->
        revision =
          page_id
          |> BrusselsWtf.Council.get_meeting_page!()
          |> Ash.load!(:current_revision)
          |> Map.fetch!(:current_revision)

        [revision.canonical_run_id, revision.nl_run_id, revision.en_run_id]
      end)
      |> MapSet.new()

    expected_operations =
      MapSet.new([
        {"fr", :canonical_generation},
        {"nl", :translation},
        {"en", :translation}
      ])

    length(runs) == 24 and MapSet.new(ids) == expected_run_ids and
      Enum.all?(runs, &(&1.status == :succeeded)) and
      MapSet.new(Enum.map(runs, & &1.meeting_page_id)) == page_ids and
      runs
      |> Enum.group_by(& &1.meeting_page_id)
      |> Enum.all?(fn {_page_id, page_runs} ->
        MapSet.new(page_runs, &{&1.locale, &1.operation}) == expected_operations
      end)
  rescue
    _error -> false
  end
end
