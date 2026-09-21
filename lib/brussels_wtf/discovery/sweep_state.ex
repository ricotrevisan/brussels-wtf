defmodule BrusselsWtf.Discovery.SweepState do
  @moduledoc "Durable opt-in admission control, UTC allowance and round-robin cursors."
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Discovery,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "discovery_sweep_states"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :initialize do
      accept []
      upsert? true
      upsert_identity :singleton
      upsert_fields []
      return_skipped_upsert? true
    end

    update :advance do
      require_atomic? false

      accept [
        :enabled,
        :hold,
        :enabled_by,
        :revision,
        :cursors,
        :commune_offset,
        :max_runs,
        :max_jobs,
        :max_unfinished,
        :daily_jobs,
        :budget_day,
        :day_used
      ]
    end
  end

  policies do
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :key, :string, allow_nil?: false, default: "global"
    attribute :enabled, :boolean, allow_nil?: false, default: false
    attribute :hold, :string
    attribute :enabled_by, :string
    attribute :revision, :integer, allow_nil?: false, default: 0
    attribute :cursors, :map, allow_nil?: false, default: %{}

    attribute :commune_offset, :integer,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0, max: 3]

    attribute :max_runs, :integer, allow_nil?: false, default: 4, constraints: [min: 1, max: 4]
    attribute :max_jobs, :integer, allow_nil?: false, default: 8, constraints: [min: 1, max: 8]

    attribute :max_unfinished, :integer,
      allow_nil?: false,
      default: 64,
      constraints: [min: 1, max: 64]

    attribute :daily_jobs, :integer,
      allow_nil?: false,
      default: 12,
      constraints: [min: 1, max: 500]

    attribute :budget_day, :date
    attribute :day_used, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    timestamps()
  end

  identities do
    identity :singleton, [:key]
  end
end
