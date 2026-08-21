defmodule BrusselsWtf.Identity.LegalEntity do
  @moduledoc "A registered organization identified by its CBE enterprise number."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Identity,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "legal_entities"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :upsert do
      primary? true
      accept [:enterprise_number, :registered_name, :status, :cbe_release_id]
      upsert? true
      upsert_identity :unique_enterprise_number
      upsert_fields [:registered_name, :status, :cbe_release_id, :updated_at]
      change BrusselsWtf.Identity.Changes.ValidateEnterpriseNumber
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :enterprise_number, :string, allow_nil?: false, public?: true
    attribute :registered_name, :string, allow_nil?: false, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:active, :inactive]
    end

    timestamps()
  end

  relationships do
    belongs_to :cbe_release, BrusselsWtf.Identity.CbeRelease,
      allow_nil?: false,
      public?: true

    has_many :names, BrusselsWtf.Identity.LegalEntityName
    has_many :establishment_units, BrusselsWtf.Identity.EstablishmentUnit
  end

  identities do
    identity :unique_enterprise_number, [:enterprise_number]
  end
end
