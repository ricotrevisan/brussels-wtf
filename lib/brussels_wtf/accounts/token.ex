defmodule BrusselsWtf.Accounts.Token do
  @moduledoc "Hashed/revocable AshAuthentication tokens for citizen principals."
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.TokenResource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "citizen_authentication_tokens"
    repo BrusselsWtf.Repo
  end

  actions do
    read :read do
      primary? true
    end

    read :for_account_deletion do
      argument :citizen_id, :string, allow_nil?: false
      argument :outstanding_jtis, {:array, :string}, allow_nil?: false
      filter expr(contains(subject, ^arg(:citizen_id)) or jti in ^arg(:outstanding_jtis))
    end

    destroy :revoke_stored do
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action([:for_account_deletion, :revoke_stored]) do
      authorize_if actor_attribute_equals(:principal, :system)
    end
  end
end
