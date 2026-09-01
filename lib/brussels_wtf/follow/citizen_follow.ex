defmodule BrusselsWtf.Follow.CitizenFollow do
  @moduledoc "A citizen-private durable personal follow, separate from collections."
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Follow,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "citizen_follows"
    repo BrusselsWtf.Repo
  end

  actions do
    read :read do
      primary? true
    end

    read :mine do
      filter expr(citizen_id == ^actor(:id))
    end

    create :import do
      accept [:citizen_id, :target_type, :target_identifier]
      upsert? true
      upsert_identity :unique_follow
    end

    destroy :remove do
      primary? true
    end
  end

  policies do
    policy action_type([:read, :create, :destroy]) do
      authorize_if expr(citizen_id == ^actor(:id) and ^actor(:principal) == :citizen)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :citizen_id, :uuid, allow_nil?: false

    attribute :target_type, :atom,
      allow_nil?: false,
      constraints: [one_of: [:dossier, :person, :legal_entity, :commune]]

    attribute :target_identifier, :string, allow_nil?: false
    timestamps()
  end

  identities do
    identity :unique_follow, [:citizen_id, :target_type, :target_identifier]
  end
end
