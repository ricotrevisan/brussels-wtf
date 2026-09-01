defmodule BrusselsWtf.Accounts.OutstandingMagicLink do
  @moduledoc false
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "citizen_outstanding_magic_links"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      accept [:email_hash, :jti, :subject, :expires_at]
    end

    destroy :remove do
      primary? true
    end

    destroy :remove_expired do
      argument :now, :utc_datetime_usec, allow_nil?: false
      filter expr(expires_at <= ^arg(:now))
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:principal, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :email_hash, :binary, allow_nil?: false, sensitive?: true
    attribute :jti, :string, allow_nil?: false, sensitive?: true
    attribute :subject, :string, allow_nil?: false, sensitive?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    timestamps()
  end

  identities do
    identity :unique_jti, [:jti]
  end
end
