defmodule BrusselsWtf.Follow.Member do
  @moduledoc "A typed stable reference to one eligible public resource."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Follow,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "follow_collection_members"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :add do
      accept [:collection_id, :target_type, :target_identifier]
      upsert? true
      upsert_identity :unique_member
    end

    destroy :remove do
      primary? true
    end
  end

  policies do
    policy action_type([:read, :create, :destroy]) do
      authorize_if expr(collection_id == ^actor(:collection_id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :target_type, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:dossier, :person, :legal_entity, :commune]]

    attribute :target_identifier, :string, allow_nil?: false, public?: true
    timestamps()
  end

  relationships do
    belongs_to :collection, BrusselsWtf.Follow.Collection,
      allow_nil?: false,
      public?: true
  end

  identities do
    identity :unique_member, [:collection_id, :target_type, :target_identifier]
  end
end
