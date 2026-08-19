defmodule BrusselsWtf.Council.PublicationRevision do
  @moduledoc "An immutable snapshot of one complete meeting-page publication."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "publication_revisions"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true
      validate fn changeset, _context -> __MODULE__.validate_payload(changeset) end

      accept [
        :meeting_page_id,
        :publication_input_hash,
        :published_at,
        :canonical_run_id,
        :nl_run_id,
        :en_run_id,
        :content
      ]
    end

    read :for_page do
      argument :meeting_page_id, :uuid, allow_nil?: false
      filter expr(meeting_page_id == ^arg(:meeting_page_id))
      prepare build(sort: [published_at: :asc, id: :asc])
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :publication_input_hash, :string, allow_nil?: false, public?: true
    attribute :published_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :content, :map, allow_nil?: false, public?: true
    timestamps()
  end

  relationships do
    belongs_to :meeting_page, BrusselsWtf.Council.MeetingPage,
      allow_nil?: false,
      public?: true

    belongs_to :canonical_run, BrusselsWtf.Council.CoverageRun,
      allow_nil?: false,
      public?: true

    belongs_to :nl_run, BrusselsWtf.Council.CoverageRun,
      allow_nil?: false,
      public?: true

    belongs_to :en_run, BrusselsWtf.Council.CoverageRun,
      allow_nil?: false,
      public?: true
  end

  def validate_payload(changeset) do
    page_id = Ash.Changeset.get_attribute(changeset, :meeting_page_id)
    input_hash = Ash.Changeset.get_attribute(changeset, :publication_input_hash)
    canonical = get_run(Ash.Changeset.get_attribute(changeset, :canonical_run_id))
    nl = get_run(Ash.Changeset.get_attribute(changeset, :nl_run_id))
    en = get_run(Ash.Changeset.get_attribute(changeset, :en_run_id))
    content = Ash.Changeset.get_attribute(changeset, :content)

    valid? =
      canonical.meeting_page_id == page_id and canonical.locale == "fr" and
        canonical.operation == :canonical_generation and canonical.status == :succeeded and
        canonical.input_hash == input_hash and
        valid_translation?(nl, canonical, "nl", page_id) and
        valid_translation?(en, canonical, "en", page_id) and
        content ==
          BrusselsWtf.Council.GenerationContract.combine(canonical.output, nl.output, en.output)

    if valid?, do: :ok, else: {:error, "publication revision does not match its coverage runs"}
  end

  def valid_for_publish?(revision_id, page_id, input_hash, published_at) do
    revision =
      __MODULE__
      |> Ash.get!(revision_id, authorize?: false, domain: BrusselsWtf.Council)

    page =
      page_id
      |> BrusselsWtf.Council.get_meeting_page!()
      |> Ash.load!(locale_variants: [:coverage_run])

    run_ids = Map.new(page.locale_variants, &{&1.locale, &1.coverage_run_id})

    revision.meeting_page_id == page_id and revision.publication_input_hash == input_hash and
      is_struct(published_at, DateTime) and
      DateTime.compare(revision.published_at, published_at) == :eq and
      run_ids == %{
        "fr" => revision.canonical_run_id,
        "nl" => revision.nl_run_id,
        "en" => revision.en_run_id
      }
  end

  defp valid_translation?(run, canonical, locale, page_id) do
    run.meeting_page_id == page_id and run.locale == locale and run.operation == :translation and
      run.status == :succeeded and run.parent_run_id == canonical.id and
      run.input["canonical_output_hash"] == canonical.output_hash
  end

  defp get_run(id) do
    Ash.get!(BrusselsWtf.Council.CoverageRun, id,
      authorize?: false,
      domain: BrusselsWtf.Council
    )
  end
end
