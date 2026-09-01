defmodule BrusselsWtf.Follow.CollectionGrant do
  @moduledoc "An explicit view-only grant for a registered citizen."
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Follow,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "follow_collection_grants"
    repo BrusselsWtf.Repo
  end

  actions do
    read :list_for_owned_collection do
      argument :collection_id, :uuid, allow_nil?: false

      filter expr(
               collection_id == ^arg(:collection_id) and
                 collection.owner_citizen_id == ^actor(:id)
             )
    end

    read :get_for_owner do
      get? true
      argument :id, :uuid, allow_nil?: false
      argument :collection_id, :uuid, allow_nil?: false

      filter expr(
               id == ^arg(:id) and collection_id == ^arg(:collection_id) and
                 collection.owner_citizen_id == ^actor(:id)
             )
    end

    read :mine do
      filter expr(citizen_id == ^actor(:id))
    end

    create :grant_view do
      accept [:collection_id, :citizen_id]
      argument :owner_citizen_id, :uuid, allow_nil?: false
    end

    destroy :revoke_view do
      argument :collection_id, :uuid, allow_nil?: false

      filter expr(
               collection_id == ^arg(:collection_id) and
                 collection.owner_citizen_id == ^actor(:id)
             )
    end

    destroy :delete_for_account do
    end
  end

  policies do
    policy action(:mine) do
      authorize_if expr(citizen_id == ^actor(:id) and ^actor(:principal) == :citizen)
    end

    policy action(:grant_view) do
      authorize_if expr(
                     ^actor(:principal) == :citizen and ^actor(:id) == ^arg(:owner_citizen_id) and
                       collection.owner_citizen_id == ^actor(:id)
                   )
    end

    policy action([:list_for_owned_collection, :get_for_owner, :revoke_view]) do
      authorize_if expr(
                     ^actor(:principal) == :citizen and collection.owner_citizen_id == ^actor(:id)
                   )
    end

    policy action(:delete_for_account) do
      authorize_if actor_attribute_equals(:principal, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :collection_id, :uuid, allow_nil?: false
    attribute :citizen_id, :uuid, allow_nil?: false
    timestamps()
  end

  relationships do
    belongs_to :collection, BrusselsWtf.Follow.Collection do
      source_attribute :collection_id
      destination_attribute :id
      define_attribute? false
      allow_nil? false
    end
  end

  identities do
    identity :unique_grant, [:collection_id, :citizen_id]
  end
end
