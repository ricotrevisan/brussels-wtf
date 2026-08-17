defmodule BrusselsWtf.Ingestion.SourceVersion do
  @moduledoc """
  An immutable byte snapshot identified by SHA-256.
  """

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
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :sha256, :string do
      allow_nil? false
      public? true
    end

    attribute :byte_size, :integer do
      allow_nil? false
      public? true
    end

    attribute :media_type, :string do
      allow_nil? false
      public? true
    end

    attribute :object_key, :string do
      allow_nil? false
      public? true
    end

    attribute :first_retrieved_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :source_record, BrusselsWtf.Ingestion.SourceRecord do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_source_record_hash, [:source_record_id, :sha256]
  end
end
