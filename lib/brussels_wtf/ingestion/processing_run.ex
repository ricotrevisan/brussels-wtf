defmodule BrusselsWtf.Ingestion.ProcessingRun do
  @moduledoc """
  One execution of a named processor against a source version.
  """

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Ingestion,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "processing_runs"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    update :complete do
      require_atomic? false
      change BrusselsWtf.Ingestion.ProcessingRun.Changes.CompleteQueued

      accept [
        :status,
        :output,
        :tool_versions,
        :diagnostics,
        :quality_measurements,
        :failure_classification,
        :started_at,
        :completed_at,
        :duration_ms
      ]
    end

    create :review_retry do
      accept [
        :source_version_id,
        :generation_key,
        :processor_role,
        :inputs,
        :processor_name,
        :processor_version,
        :config_hash,
        :status,
        :output,
        :tool_versions,
        :diagnostics,
        :quality_measurements,
        :failure_classification,
        :started_at,
        :completed_at,
        :duration_ms
      ]
    end

    create :upsert do
      primary? true

      accept [
        :source_version_id,
        :generation_key,
        :processor_role,
        :inputs,
        :processor_name,
        :processor_version,
        :config_hash,
        :status,
        :output,
        :tool_versions,
        :diagnostics,
        :quality_measurements,
        :failure_classification,
        :started_at,
        :completed_at,
        :duration_ms
      ]

      upsert? true
      upsert_identity :unique_processing
      upsert_fields []
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :generation_key, :string do
      allow_nil? false
      public? true
      default "automatic"
    end

    attribute :processor_role, :atom do
      allow_nil? false
      public? true
      default :native_extraction
      constraints one_of: [:native_extraction, :ocr, :relationship_verification]
    end

    attribute :inputs, :map, allow_nil?: false, public?: true, default: %{}
    attribute :tool_versions, :map, allow_nil?: false, public?: true, default: %{}
    attribute :diagnostics, :map, allow_nil?: false, public?: true, default: %{}
    attribute :quality_measurements, :map, allow_nil?: false, public?: true, default: %{}
    attribute :failure_classification, :string, public?: true
    attribute :started_at, :utc_datetime_usec, public?: true
    attribute :completed_at, :utc_datetime_usec, public?: true
    attribute :duration_ms, :integer, allow_nil?: false, public?: true, default: 0

    attribute :processor_name, :string do
      allow_nil? false
      public? true
    end

    attribute :processor_version, :string do
      allow_nil? false
      public? true
    end

    attribute :config_hash, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:queued, :succeeded, :failed]
    end

    attribute :output, :map, public?: true

    timestamps()
  end

  relationships do
    belongs_to :source_version, BrusselsWtf.Ingestion.SourceVersion do
      allow_nil? false
      public? true
    end
  end

  relationships do
    has_many :originated_derived_artifacts, BrusselsWtf.Ingestion.DerivedArtifact
    has_many :artifact_links, BrusselsWtf.Ingestion.ProcessingRunArtifact
    has_many :attempts, BrusselsWtf.Ingestion.ProcessingAttempt

    many_to_many :derived_artifacts, BrusselsWtf.Ingestion.DerivedArtifact do
      through BrusselsWtf.Ingestion.ProcessingRunArtifact
      source_attribute_on_join_resource :processing_run_id
      destination_attribute_on_join_resource :derived_artifact_id
    end
  end

  def review_context(run) do
    run = Ash.load!(run, [:attempts, :derived_artifacts])

    %{
      id: run.id,
      generation_key: run.generation_key,
      processor_role: run.processor_role,
      processor_name: run.processor_name,
      processor_version: run.processor_version,
      config_hash: run.config_hash,
      status: run.status,
      failure_classification: run.failure_classification,
      tool_versions: run.tool_versions,
      diagnostics: run.diagnostics,
      quality_measurements: run.quality_measurements,
      timing: %{
        started_at: run.started_at,
        completed_at: run.completed_at,
        duration_ms: run.duration_ms
      },
      attempts:
        run.attempts
        |> Enum.sort_by(& &1.attempt)
        |> Enum.map(fn attempt ->
          %{
            attempt: attempt.attempt,
            status: attempt.status,
            failure_classification: attempt.failure_classification,
            diagnostics: attempt.diagnostics,
            tool_versions: attempt.tool_versions,
            quality_measurements: attempt.quality_measurements,
            started_at: attempt.started_at,
            completed_at: attempt.completed_at,
            duration_ms: attempt.duration_ms
          }
        end),
      artifacts:
        Enum.map(run.derived_artifacts, fn artifact ->
          %{
            output_kind: artifact.output_kind,
            output_sha256: artifact.output_sha256,
            media_type: artifact.media_type,
            byte_size: artifact.byte_size,
            schema_version: artifact.schema_version,
            quality_measurements: artifact.quality_measurements
          }
        end)
    }
    |> Jason.encode!()
    |> Jason.decode!()
  end

  identities do
    identity :unique_processing, [
      :source_version_id,
      :processor_name,
      :processor_version,
      :config_hash,
      :generation_key
    ]
  end
end
