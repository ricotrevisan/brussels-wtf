defmodule BrusselsWtf.Council.Agenda do
  @moduledoc "One normalized agenda version for exactly one council meeting."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "agendas"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true
      accept [:council_meeting_id, :source_version_id, :kind, :language]
      upsert? true
      upsert_identity :unique_source_version
      upsert_fields []
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:base, :complementary, :supplement, :addendum, :corrected, :final]
    end

    attribute :language, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:fr, :nl, :en, :bilingual]
    end

    timestamps()
  end

  relationships do
    belongs_to :council_meeting, BrusselsWtf.Council.Meeting, allow_nil?: false, public?: true

    belongs_to :source_version, BrusselsWtf.Ingestion.SourceVersion,
      allow_nil?: false,
      public?: true
  end

  identities do
    identity :unique_source_version, [:source_version_id]
  end
end
