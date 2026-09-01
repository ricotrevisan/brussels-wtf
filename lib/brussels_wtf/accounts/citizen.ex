defmodule BrusselsWtf.Accounts.Citizen do
  @moduledoc "A citizen principal, never an editor principal."
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "citizens"
    repo BrusselsWtf.Repo
  end

  actions do
    create :register do
      accept [:email, :last_sign_in_at]
    end

    read :read do
      primary? true
    end

    read :by_email do
      get? true
      argument :email, :string, allow_nil?: false, sensitive?: true
      filter expr(email == ^arg(:email))
    end

    update :sign_in do
      accept [:last_sign_in_at]
      require_atomic? false
    end

    update :change_email do
      accept [:email]
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
    attribute :last_sign_in_at, :utc_datetime_usec, allow_nil?: false
    timestamps()
  end

  identities do
    identity :unique_email, [:email]
  end
end
