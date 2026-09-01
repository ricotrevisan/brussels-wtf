defmodule BrusselsWtf.Follow.RetentionWarning do
  @moduledoc "An immutable warning delivery for one sign-in inactivity cycle."
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Follow,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "citizen_retention_warnings"
    repo BrusselsWtf.Repo
  end

  actions do
    create :record do
      accept [
        :citizen_id,
        :inactivity_cycle_at,
        :days_before_deletion,
        :warned_at,
        :delivery_status,
        :delivery_attempted_at
      ]

      upsert? true
      upsert_identity :one_warning
      upsert_fields []
    end

    update :record_delivery do
      accept [:delivery_status, :delivery_attempted_at]
      require_atomic? false
    end

    read :read do
      primary? true
    end

    destroy :purge do
      primary? true
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
    policy always() do
      authorize_if actor_attribute_equals(:principal, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :citizen_id, :uuid, allow_nil?: false
    attribute :inactivity_cycle_at, :utc_datetime_usec, allow_nil?: false

    attribute :days_before_deletion, :integer,
      allow_nil?: false,
      constraints: [min: 7, max: 30]

    attribute :warned_at, :utc_datetime_usec, allow_nil?: false

    attribute :delivery_status, :atom,
      allow_nil?: false,
      default: :delivered,
      constraints: [one_of: [:delivered, :failed]]

    attribute :delivery_attempted_at, :utc_datetime_usec, allow_nil?: false
  end

  identities do
    identity :one_warning, [:citizen_id, :inactivity_cycle_at, :days_before_deletion]
  end
end
