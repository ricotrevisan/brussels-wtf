defmodule BrusselsWtf.Accounts.Session do
  @moduledoc "A revocable citizen session with idle and absolute deadlines."
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "citizen_sessions"
    repo BrusselsWtf.Repo
  end

  actions do
    create :open do
      accept [:citizen_id, :last_active_at, :expires_at]
    end

    read :read do
      primary? true
    end

    read :by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    update :touch do
      accept [:last_active_at]
      require_atomic? false
    end

    destroy :revoke do
      primary? true
    end
  end

  policies do
    policy action(:open) do
      authorize_if actor_attribute_equals(:principal, :system)
    end

    policy action([:read, :by_id, :touch, :revoke]) do
      authorize_if actor_attribute_equals(:principal, :system)
      authorize_if expr(citizen_id == ^actor(:id) and ^actor(:principal) == :citizen)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :citizen_id, :uuid, allow_nil?: false
    attribute :last_active_at, :utc_datetime_usec, allow_nil?: false
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    timestamps()
  end
end
