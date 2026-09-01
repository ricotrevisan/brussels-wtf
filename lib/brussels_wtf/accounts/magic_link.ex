defmodule BrusselsWtf.Accounts.MagicLink do
  @moduledoc "A hashed, single-use, 15-minute citizen login capability."
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "citizen_magic_links"
    repo BrusselsWtf.Repo
  end

  actions do
    create :issue do
      accept [:email, :token_hash, :expires_at]
    end

    read :read do
      primary? true
    end

    read :by_hash do
      get? true
      argument :token_hash, :binary, allow_nil?: false, sensitive?: true
      filter expr(token_hash == ^arg(:token_hash) and is_nil(consumed_at))
    end

    update :consume do
      accept [:consumed_at]
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :email, :string, allow_nil?: false, sensitive?: true
    attribute :token_hash, :binary, allow_nil?: false, sensitive?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :consumed_at, :utc_datetime_usec
    timestamps()
  end

  identities do
    identity :unique_token_hash, [:token_hash]
  end
end
