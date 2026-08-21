defmodule BrusselsWtf.Identity.EstablishmentUnit do
  @moduledoc "A CBE establishment unit attached beneath one legal entity."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Identity,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "establishment_units"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :upsert do
      primary? true
      accept [:unit_number, :legal_entity_id, :cbe_release_id, :name, :status, :started_on]
      upsert? true
      upsert_identity :unique_unit_number
      upsert_fields [:legal_entity_id, :cbe_release_id, :name, :status, :started_on, :updated_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :unit_number, :string, allow_nil?: false, public?: true
    attribute :name, :string, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:active, :inactive]
    end

    attribute :started_on, :date, public?: true
    timestamps()
  end

  relationships do
    belongs_to :legal_entity, BrusselsWtf.Identity.LegalEntity,
      allow_nil?: false,
      public?: true

    belongs_to :cbe_release, BrusselsWtf.Identity.CbeRelease,
      allow_nil?: false,
      public?: true
  end

  identities do
    identity :unique_unit_number, [:unit_number]
  end
end
