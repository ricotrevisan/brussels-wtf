defmodule BrusselsWtf.Ingestion.ProcessingAttempt do
  @moduledoc "Immutable record of one bounded execution attempt within a processing generation."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Ingestion,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "processing_attempts"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :processing_run_id,
        :attempt,
        :status,
        :started_at,
        :completed_at,
        :duration_ms,
        :failure_classification,
        :diagnostics,
        :tool_versions,
        :quality_measurements
      ]

      upsert? true
      upsert_identity :unique_run_attempt
      upsert_fields []
      return_skipped_upsert? true
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :attempt, :integer, allow_nil?: false, public?: true, constraints: [min: 1]

    attribute :status, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:succeeded, :failed]]

    attribute :started_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :completed_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :duration_ms, :integer, allow_nil?: false, public?: true, constraints: [min: 0]
    attribute :failure_classification, :string, public?: true
    attribute :diagnostics, :map, allow_nil?: false, public?: true, default: %{}
    attribute :tool_versions, :map, allow_nil?: false, public?: true, default: %{}
    attribute :quality_measurements, :map, allow_nil?: false, public?: true, default: %{}
    timestamps()
  end

  relationships do
    belongs_to :processing_run, BrusselsWtf.Ingestion.ProcessingRun,
      allow_nil?: false,
      public?: true
  end

  identities do
    identity :unique_run_attempt, [:processing_run_id, :attempt]
  end
end
