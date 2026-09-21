defmodule BrusselsWtf.Discovery.SweepRun do
  @moduledoc "Private per-extraction pagination and exclusion receipt, independent of Oban."
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Discovery,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "discovery_sweep_runs"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :extraction_run_id,
        :contract,
        :commune,
        :next_chunk,
        :total_chunks,
        :status,
        :skip_reason,
        :measurements,
        :examinations,
        :new_jobs
      ]

      upsert? true
      upsert_identity :generation

      upsert_fields [
        :next_chunk,
        :total_chunks,
        :status,
        :skip_reason,
        :measurements,
        :examinations,
        :new_jobs
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
    attribute :contract, :string, allow_nil?: false
    attribute :commune, :string, allow_nil?: false
    attribute :next_chunk, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :total_chunks, :integer, constraints: [min: 0]

    attribute :status, :atom,
      allow_nil?: false,
      constraints: [one_of: [:eligible, :excluded, :admitted]]

    attribute :skip_reason, :string
    attribute :measurements, :map, allow_nil?: false, default: %{}
    attribute :examinations, :integer, allow_nil?: false, default: 0
    attribute :new_jobs, :integer, allow_nil?: false, default: 0
    timestamps()
  end

  relationships do
    belongs_to :extraction_run, BrusselsWtf.Ingestion.ProcessingRun, allow_nil?: false
  end

  identities do
    identity :generation, [:extraction_run_id, :contract]
  end
end
