defmodule BrusselsWtf.Follow.RetentionWarning do
  @moduledoc "A controlled inactivity warning; recording it never changes sign-in activity."
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
      accept [:citizen_id, :days_before_deletion, :warned_at]
      upsert? true
      upsert_identity :one_warning
    end

    read :read do
      primary? true
    end

    destroy :purge do
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
    attribute :citizen_id, :uuid, allow_nil?: false
    attribute :days_before_deletion, :integer, allow_nil?: false, constraints: [min: 7, max: 30]
    attribute :warned_at, :utc_datetime_usec, allow_nil?: false
  end

  identities do
    identity :one_warning, [:citizen_id, :days_before_deletion]
  end
end
