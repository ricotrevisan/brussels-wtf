defmodule BrusselsWtf.Ingestion.SourceRecord do
  @moduledoc "An authoritative published item whose byte versions live separately."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Ingestion,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "source_records"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :upsert do
      primary? true
      accept [:commune_id, :origin_url, :role, :original_language]
      upsert? true
      upsert_identity :unique_commune_origin
      upsert_fields []
    end

    update :reclassify do
      accept [:role]
    end

    update :link_meeting do
      accept [:council_meeting_id]
    end

    update :link_agenda_item do
      accept [:agenda_item_id]
    end

    read :by_origin do
      get? true
      argument :commune_id, :uuid, allow_nil?: false
      argument :origin_url, :string, allow_nil?: false
      filter expr(commune_id == ^arg(:commune_id) and origin_url == ^arg(:origin_url))
      prepare build(load: [:versions])
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :origin_url, :string, allow_nil?: false, public?: true

    attribute :role, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :index,
                    :agenda,
                    :complementary_agenda,
                    :project,
                    :explanatory_note,
                    :complementary_explanatory_note,
                    :explanatory_notes,
                    :supplement,
                    :addendum,
                    :minutes,
                    :register,
                    :motion,
                    :question,
                    :interpellation,
                    :document_listing,
                    :item_listing,
                    :supporting_document,
                    :recording
                  ]
    end

    attribute :original_language, :atom do
      allow_nil? false
      public? true
      default :bilingual
      constraints one_of: [:fr, :nl, :en, :bilingual]
    end

    timestamps()
  end

  relationships do
    belongs_to :commune, BrusselsWtf.Ingestion.Commune do
      allow_nil? false
      public? true
    end

    belongs_to :council_meeting, BrusselsWtf.Council.Meeting do
      public? true
    end

    belongs_to :agenda_item, BrusselsWtf.Council.AgendaItem do
      public? true
    end

    has_many :versions, BrusselsWtf.Ingestion.SourceVersion
  end

  identities do
    identity :unique_commune_origin, [:commune_id, :origin_url]
  end
end
