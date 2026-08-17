defmodule BrusselsWtf.Council.Meeting do
  @moduledoc """
  A scheduled municipal council session.
  """

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "council_meetings"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :upsert do
      primary? true
      accept [:commune_id, :municipal_identifier, :scheduled_on]
      upsert? true
      upsert_identity :unique_municipal_meeting
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :municipal_identifier, :string do
      allow_nil? false
      public? true
    end

    attribute :scheduled_on, :date do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :commune, BrusselsWtf.Ingestion.Commune do
      allow_nil? false
      public? true
    end

    has_one :meeting_page, BrusselsWtf.Council.MeetingPage do
      destination_attribute :council_meeting_id
    end

    has_many :agenda_items, BrusselsWtf.Council.AgendaItem do
      destination_attribute :council_meeting_id
    end
  end

  identities do
    identity :unique_municipal_meeting, [:commune_id, :municipal_identifier]
  end
end
