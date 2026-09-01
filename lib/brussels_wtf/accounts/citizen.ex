defmodule BrusselsWtf.Accounts.Citizen do
  @moduledoc "A citizen AshAuthentication principal, never an editor principal."
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "citizens"
    repo BrusselsWtf.Repo
  end

  authentication do
    session_identifier(:jti)

    tokens do
      enabled?(true)
      token_resource(BrusselsWtf.Accounts.Token)
      store_all_tokens?(true)
      require_token_presence_for_authentication?(true)

      signing_secret(fn _, _ ->
        Application.fetch_env(:brussels_wtf, :citizen_token_signing_secret)
      end)
    end

    add_ons do
      log_out_everywhere do
      end
    end

    strategies do
      magic_link do
        identity_field(:email)
        registration_enabled?(true)
        require_interaction?(true)
        token_lifetime({15, :minutes})
        sender(BrusselsWtf.Accounts.Citizen.Senders.SendMagicLink)
      end
    end
  end

  actions do
    defaults [:read]

    read :retention_candidates do
    end

    read :get_by_subject do
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    update :record_sign_in do
      accept [:last_sign_in_at]
      require_atomic? false
    end

    update :apply_email_change do
      accept [:email]
      require_atomic? false
    end

    destroy :delete_account do
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action([:read, :record_sign_in]) do
      authorize_if expr(id == ^actor(:id) and ^actor(:principal) == :citizen)
    end

    policy action(:retention_candidates) do
      authorize_if actor_attribute_equals(:principal, :system)
    end

    policy action([:apply_email_change, :delete_account]) do
      authorize_if actor_attribute_equals(:principal, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :email, :string, allow_nil?: false, sensitive?: true, public?: false
    attribute :last_sign_in_at, :utc_datetime_usec

    attribute :preferred_locale, :string,
      allow_nil?: false,
      default: "en",
      constraints: [match: ~r/^(fr|nl|en)$/]

    timestamps()
  end

  identities do
    identity :unique_email, [:email]
  end
end
