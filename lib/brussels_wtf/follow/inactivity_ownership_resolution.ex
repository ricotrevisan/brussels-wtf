defmodule BrusselsWtf.Follow.InactivityOwnershipResolution do
  @moduledoc "A citizen's revocable choice for one owned collection and sign-in inactivity cycle."
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Follow,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "citizen_inactivity_ownership_resolutions"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :select do
      accept [:citizen_id, :collection_id, :inactivity_cycle_at, :choice]
      upsert? true
      upsert_identity :one_choice
      upsert_fields [:choice]
    end

    destroy :revoke do
      primary? true
    end

    read :for_cycle do
      argument :citizen_id, :uuid, allow_nil?: false
      argument :inactivity_cycle_at, :utc_datetime_usec, allow_nil?: false

      filter expr(
               citizen_id == ^arg(:citizen_id) and
                 inactivity_cycle_at == ^arg(:inactivity_cycle_at)
             )
    end

    read :for_account_deletion do
      argument :citizen_id, :uuid, allow_nil?: false
      filter expr(citizen_id == ^arg(:citizen_id))
    end

    destroy :delete_for_account do
      argument :citizen_id, :uuid, allow_nil?: false
      filter expr(citizen_id == ^arg(:citizen_id))
    end
  end

  policies do
    policy action([:select, :revoke, :read]) do
      authorize_if expr(citizen_id == ^actor(:id) and ^actor(:principal) == :citizen)
    end

    policy action([:for_cycle, :for_account_deletion, :delete_for_account]) do
      authorize_if actor_attribute_equals(:principal, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :citizen_id, :uuid, allow_nil?: false
    attribute :collection_id, :uuid, allow_nil?: false
    attribute :inactivity_cycle_at, :utc_datetime_usec, allow_nil?: false
    attribute :choice, :atom, allow_nil?: false, constraints: [one_of: [:delete, :transfer]]
    timestamps()
  end

  identities do
    identity :one_choice, [:citizen_id, :collection_id, :inactivity_cycle_at]
  end
end
