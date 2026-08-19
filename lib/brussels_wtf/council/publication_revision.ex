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
end
