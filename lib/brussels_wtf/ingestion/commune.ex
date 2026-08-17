defmodule BrusselsWtf.Ingestion.Commune do
  @moduledoc """
  One of the four MVP municipal authorities.
  """

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Ingestion,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "communes"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:slug, :name, :index_url]
      upsert? true
      upsert_identity :unique_slug
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :slug, :string do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :index_url, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
