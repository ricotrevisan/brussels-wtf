defmodule BrusselsWtf.Council.ProviderCreditCheck do
  @moduledoc """
  One reading of the paid coverage provider's remaining credit.

  `level` is what this reading found. `notified_level` is what Rico was last told,
  carried forward from the previous check, so each change of state alerts once and a
  failed alert is retried by the next check.
  """

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "provider_credit_checks"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :provider,
        :trigger,
        :level,
        :notified_level,
        :key_remaining_cents,
        :account_remaining_cents,
        :resumed_pages
      ]
    end

    read :latest do
      get? true
      argument :provider, :string, allow_nil?: false
      filter expr(provider == ^arg(:provider))
      prepare build(sort: [inserted_at: :desc, id: :desc], limit: 1)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :trigger, :string, allow_nil?: false, public?: true

    attribute :level, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:ok, :low, :exhausted, :unavailable]
    end

    attribute :notified_level, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:ok, :low, :exhausted]
    end

    attribute :key_remaining_cents, :integer, public?: true
    attribute :account_remaining_cents, :integer, public?: true
    attribute :resumed_pages, :integer, allow_nil?: false, default: 0, public?: true

    create_timestamp :inserted_at
  end
end
