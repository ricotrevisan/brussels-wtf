defmodule BrusselsWtf.Ingestion.SourceLocator do
  @moduledoc "An exact discovered URL plus its parent index and meeting context."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Ingestion,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "source_locators"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :upsert do
      primary? true

      accept [
        :commune_id,
        :url,
        :parent_index_url,
        :meeting_identifier,
        :scheduled_on,
        :role,
        :language,
        :observed_label,
        :item_identifier,
        :dossier_identifier,
        :discovered_at,
        :next_fetch_at
      ]

      change BrusselsWtf.Ingestion.Changes.SetLocatorDiscoveryKey
      upsert? true
      upsert_identity :unique_discovery_context
      upsert_fields []
      return_skipped_upsert? true
    end

    read :documents_for_commune do
      argument :commune_id, :uuid, allow_nil?: false
      filter expr(commune_id == ^arg(:commune_id) and role != :index)
      prepare build(sort: [url: :asc])
    end

    read :for_commune do
      argument :commune_id, :uuid, allow_nil?: false
      filter expr(commune_id == ^arg(:commune_id))
    end

    read :due_for_fetch do
      argument :now, :utc_datetime_usec, allow_nil?: false
      filter expr(not is_nil(next_fetch_at) and next_fetch_at <= ^arg(:now))
      prepare build(sort: [next_fetch_at: :asc, id: :asc])
    end

    update :schedule_fetch do
      primary? true
      accept [:next_fetch_at, :last_checked_at, :last_changed_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :url, :string, allow_nil?: false, public?: true
    attribute :discovery_key, :string, allow_nil?: false, public?: true
    attribute :parent_index_url, :string, allow_nil?: false, public?: true
    attribute :meeting_identifier, :string, allow_nil?: false, public?: true
    attribute :scheduled_on, :date, public?: true

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
                    :mandate_declaration,
                    :gazette_annex,
                    :recording
                  ]
    end

    attribute :language, :atom do
      allow_nil? false
      public? true
      default :bilingual
      constraints one_of: [:fr, :nl, :en, :bilingual]
    end

    attribute :observed_label, :string, public?: true
    attribute :item_identifier, :string, public?: true
    attribute :dossier_identifier, :string, public?: true
    attribute :discovered_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :next_fetch_at, :utc_datetime_usec, public?: true
    attribute :last_checked_at, :utc_datetime_usec, public?: true
    attribute :last_changed_at, :utc_datetime_usec, public?: true
    timestamps()
  end

  relationships do
    belongs_to :commune, BrusselsWtf.Ingestion.Commune do
      allow_nil? false
      public? true
    end

    has_many :observations, BrusselsWtf.Ingestion.RetrievalObservation
  end

  identities do
    identity :unique_discovery_context, [:commune_id, :url, :discovery_key]
  end
end
