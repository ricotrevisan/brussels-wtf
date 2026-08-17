defmodule BrusselsWtf.Ingestion.SourceRecord do
  @moduledoc """
  An authoritative published item. Versions of its bytes live separately.
  """

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
      upsert_identity :unique_origin
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :origin_url, :string do
      allow_nil? false
      public? true
    end

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:agenda, :supplement, :addendum, :minutes, :register]
    end

    attribute :original_language, :atom do
      allow_nil? false
      public? true
      default :fr
      constraints one_of: [:fr, :nl, :en]
    end

    timestamps()
  end

  relationships do
    belongs_to :commune, BrusselsWtf.Ingestion.Commune do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_origin, [:origin_url]
  end
end
