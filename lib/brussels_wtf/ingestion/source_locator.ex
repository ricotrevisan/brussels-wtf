defmodule BrusselsWtf.Ingestion.SourceLocator do
  @moduledoc """
  An exact discovered URL plus its parent index and meeting context.
  """

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
      accept [:commune_id, :url, :parent_index_url, :meeting_identifier, :role, :discovered_at]
      upsert? true
      upsert_identity :unique_url
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :url, :string do
      allow_nil? false
      public? true
    end

    attribute :parent_index_url, :string do
      allow_nil? false
      public? true
    end

    attribute :meeting_identifier, :string do
      allow_nil? false
      public? true
    end

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:agenda, :supplement, :addendum, :minutes, :register]
    end

    attribute :discovered_at, :utc_datetime_usec do
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
  end

  identities do
    identity :unique_url, [:url]
  end
end
