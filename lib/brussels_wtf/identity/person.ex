defmodule BrusselsWtf.Identity.Person do
  @moduledoc "A privately resolved natural person with an explicit evidence basis."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Identity,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "people"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :legal_name,
        :explicit_identifier,
        :resolution_basis,
        :corroborating_facts
      ]

      change BrusselsWtf.Identity.Changes.ValidatePersonResolution
    end

    update :retire do
      require_atomic? false
      accept [:retired_into_id]
      change set_attribute(:status, :retired)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :legal_name, :string, allow_nil?: false, public?: true
    attribute :explicit_identifier, :string, public?: true

    attribute :resolution_basis, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:explicit_identifier, :corroborated_name]
    end

    attribute :corroborating_facts, :map, allow_nil?: false, public?: true, default: %{}

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :active
      constraints one_of: [:active, :retired]
    end

    timestamps()
  end

  relationships do
    belongs_to :retired_into, BrusselsWtf.Identity.Person, public?: true
  end

  identities do
    identity :unique_explicit_identifier, [:explicit_identifier]
  end
end
