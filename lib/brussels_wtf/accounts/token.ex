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

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end
end
