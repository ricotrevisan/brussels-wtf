defmodule BrusselsWtf.Council.PublicationEvent do
  @moduledoc "An append-only record of a publication lifecycle transition."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "publication_events"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :meeting_page_id,
        :publication_revision_id,
        :event_type,
        :actor_id,
        :occurred_at,
        :publication_metadata,
        :details
      ]
    end

    read :for_page do
      argument :meeting_page_id, :uuid, allow_nil?: false
      filter expr(meeting_page_id == ^arg(:meeting_page_id))
      prepare build(sort: [occurred_at: :asc, id: :asc])
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :event_type, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :published,
                    :factual_correction,
                    :typography_correction,
                    :withdrawn,
                    :republished
                  ]
    end

    attribute :actor_id, :string, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :publication_metadata, :map, allow_nil?: false, public?: true
    attribute :details, :map, allow_nil?: false, public?: true, default: %{}
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :meeting_page, BrusselsWtf.Council.MeetingPage,
      allow_nil?: false,
      public?: true

    belongs_to :publication_revision, BrusselsWtf.Council.PublicationRevision, public?: true
  end
end
