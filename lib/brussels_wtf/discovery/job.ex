defmodule BrusselsWtf.Discovery.Job do
  @moduledoc "Private, immutable discovery input and its bounded execution state."
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Discovery,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "discovery_jobs"
    repo BrusselsWtf.Repo

    custom_indexes do
      index [:state, :available_at]
      index [:state], unique: true, where: "state = 'leased'", name: "discovery_one_lease"
    end
  end

  actions do
    defaults [:read]

    create :enqueue do
      accept [
        :batch_ids,
        :requested_by,
        :extraction_run_id,
        :source_version_id,
        :derived_artifact_id,
        :chunk,
        :contract,
        :input_hash,
        :lines,
        :source_context,
        :measurements
      ]

      upsert? true
      upsert_identity :unique_input
      upsert_fields []
      return_skipped_upsert? true
    end

    update :transition do
      require_atomic? false

      accept [
        :batch_ids,
        :state,
        :attempts,
        :available_at,
        :lease_digest,
        :lease_expires_at,
        :failure_reason,
        :failure_receipts,
        :processor,
        :result,
        :result_hash,
        :mention_count,
        :completed_at
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
    attribute :batch_ids, {:array, :uuid}, allow_nil?: false
    attribute :requested_by, :string, allow_nil?: false
    attribute :chunk, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :contract, :string, allow_nil?: false
    attribute :input_hash, :string, allow_nil?: false
    attribute :lines, {:array, :map}, allow_nil?: false, sensitive?: true
    attribute :source_context, :map, allow_nil?: false, sensitive?: true
    attribute :measurements, :map, allow_nil?: false

    attribute :state, :atom,
      allow_nil?: false,
      default: :queued,
      constraints: [one_of: [:queued, :leased, :completed, :paused, :failed]]

    attribute :attempts, :integer, allow_nil?: false, default: 0, constraints: [min: 0, max: 3]
    attribute :available_at, :utc_datetime_usec
    attribute :lease_digest, :string, sensitive?: true
    attribute :lease_expires_at, :utc_datetime_usec
    attribute :failure_reason, :string

    attribute :failure_receipts, {:array, :map},
      allow_nil?: false,
      default: [],
      sensitive?: true,
      constraints: [max_length: 3]

    attribute :processor, :map, sensitive?: true
    attribute :result, :map, sensitive?: true
    attribute :result_hash, :string
    attribute :mention_count, :integer, allow_nil?: false, default: 0
    attribute :completed_at, :utc_datetime_usec
    timestamps()
  end

  relationships do
    belongs_to :extraction_run, BrusselsWtf.Ingestion.ProcessingRun, allow_nil?: false
    belongs_to :source_version, BrusselsWtf.Ingestion.SourceVersion, allow_nil?: false
    belongs_to :derived_artifact, BrusselsWtf.Ingestion.DerivedArtifact, allow_nil?: false
  end

  identities do
    identity :unique_input, [:extraction_run_id, :chunk, :contract]
    identity :unique_input_hash, [:input_hash, :contract]
  end
end
