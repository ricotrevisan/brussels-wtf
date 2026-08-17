defmodule BrusselsWtf.Ingestion.SourceVersion do
  @moduledoc "An immutable byte snapshot identified by SHA-256."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Ingestion,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "source_versions"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :upsert do
      primary? true

      accept [
        :source_record_id,
        :sha256,
        :byte_size,
        :media_type,
        :object_key,
        :first_retrieved_at
      ]

      upsert? true
      upsert_identity :unique_source_record_hash
      upsert_fields []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :sha256, :string, allow_nil?: false, public?: true
    attribute :byte_size, :integer, allow_nil?: false, public?: true
    attribute :media_type, :string, allow_nil?: false, public?: true
    attribute :object_key, :string, allow_nil?: false, public?: true
    attribute :first_retrieved_at, :utc_datetime_usec, allow_nil?: false, public?: true
    timestamps()
  end

  relationships do
    belongs_to :source_record, BrusselsWtf.Ingestion.SourceRecord do
      allow_nil? false
      public? true
    end

    has_many :processing_runs, BrusselsWtf.Ingestion.ProcessingRun
    has_many :observations, BrusselsWtf.Ingestion.RetrievalObservation
  end

  identities do
    identity :unique_source_record_hash, [:source_record_id, :sha256]
  end
end
