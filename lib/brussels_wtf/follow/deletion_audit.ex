defmodule BrusselsWtf.Follow.DeletionAudit do
  @moduledoc "Minimum non-identifying proof that account deletion completed."
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Follow,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "citizen_deletion_audits"
    repo BrusselsWtf.Repo
  end

  actions do
    create :record do
      accept [:operation_id, :completed_at, :reason]
    end

    read :read do
      primary? true
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:principal, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :operation_id, :uuid, allow_nil?: false
    attribute :completed_at, :utc_datetime_usec, allow_nil?: false

    attribute :reason, :atom,
      allow_nil?: false,
      constraints: [one_of: [:citizen_request, :inactivity]]
  end

  identities do
    identity :operation, [:operation_id]
  end
end
