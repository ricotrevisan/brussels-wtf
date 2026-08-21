defmodule BrusselsWtf.Council.CoverageReservation do
  @moduledoc "One persisted spending reservation made before a paid coverage call."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "coverage_reservations"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :reserve do
      public? false
      primary? true

      accept [
        :coverage_budget_id,
        :meeting_page_id,
        :publication_input_hash,
        :operation,
        :locale,
        :provider,
        :model,
        :retry,
        :call_key,
        :estimated_cost_cents,
        :reserved_cents,
        :status
      ]
    end

    update :settle do
      public? false
      require_atomic? false

      accept [
        :coverage_run_id,
        :final_cost_cents,
        :charged_cents,
        :input_usage,
        :output_usage,
        :status,
        :settled_at
      ]
    end

    update :begin_execution do
      public? false
      require_atomic? false
      accept [:status]
    end

    update :mark_reconciliation_pending do
      public? false
      require_atomic? false
      accept [:coverage_run_id, :input_usage, :output_usage, :status]
    end

    update :fail_reconciliation do
      public? false
      require_atomic? false

      accept [
        :coverage_run_id,
        :input_usage,
        :output_usage,
        :status,
        :reconciliation_failure,
        :settled_at
      ]
    end

    read :by_call_key do
      get? true
      argument :call_key, :string, allow_nil?: false
      filter expr(call_key == ^arg(:call_key))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :publication_input_hash, :string, allow_nil?: false, public?: true

    attribute :operation, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:canonical_generation, :translation]
    end

    attribute :locale, :string do
      allow_nil? false
      public? true
      constraints match: ~r/^(fr|nl|en)$/
    end

    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :model, :string, allow_nil?: false, public?: true
    attribute :retry, :integer, allow_nil?: false, public?: true, constraints: [min: 1]
    attribute :call_key, :string, allow_nil?: false, public?: true

    attribute :estimated_cost_cents, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :reserved_cents, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :final_cost_cents, :integer, public?: true, constraints: [min: 0]
    attribute :charged_cents, :integer, public?: true, constraints: [min: 0]
    attribute :input_usage, :map, allow_nil?: false, public?: true, default: %{}
    attribute :output_usage, :map, allow_nil?: false, public?: true, default: %{}

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :reserved

      constraints one_of: [
                    :reserved,
                    :executing,
                    :reconciliation_pending,
                    :settled,
                    :reconciliation_failed
                  ]
    end

    attribute :reconciliation_failure, :string, public?: true
    attribute :settled_at, :utc_datetime_usec, public?: true
    timestamps()
  end

  relationships do
    belongs_to :coverage_budget, BrusselsWtf.Council.CoverageBudget,
      allow_nil?: false,
      public?: true

    belongs_to :meeting_page, BrusselsWtf.Council.MeetingPage,
      allow_nil?: false,
      public?: true

    belongs_to :coverage_run, BrusselsWtf.Council.CoverageRun, public?: true
  end

  identities do
    identity :unique_call_key, [:call_key]
  end
end
