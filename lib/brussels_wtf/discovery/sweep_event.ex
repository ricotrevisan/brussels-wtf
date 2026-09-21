defmodule BrusselsWtf.Discovery.SweepEvent do
  @moduledoc "Append-only safe operation receipts; never transport history or source text."
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Discovery,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "discovery_sweep_events"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      accept [:operation, :actor_id, :report]
    end
  end

  policies do
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :operation, :string, allow_nil?: false
    attribute :actor_id, :string, allow_nil?: false
    attribute :report, :map, allow_nil?: false
    create_timestamp :inserted_at
  end
end
