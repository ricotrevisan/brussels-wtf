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
    read :read do
      primary? true
    end

    read :mine do
      filter expr(citizen_id == ^actor(:id))
    end

    create :grant do
      accept [:collection_id, :citizen_id]
    end

    destroy :revoke do
      primary? true
    end
  end

  policies do
    policy action(:mine) do
      authorize_if expr(citizen_id == ^actor(:id) and ^actor(:principal) == :citizen)
    end

    policy action([:read, :grant, :revoke]) do
      authorize_if actor_attribute_equals(:principal, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :collection_id, :uuid, allow_nil?: false
    attribute :citizen_id, :uuid, allow_nil?: false
    timestamps()
  end

  identities do
    identity :unique_grant, [:collection_id, :citizen_id]
  end
end
