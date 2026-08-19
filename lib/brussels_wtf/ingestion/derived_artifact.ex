defmodule BrusselsWtf.Ingestion.DerivedArtifact do
  @moduledoc "An immutable processor output with input/output hashes and private object provenance."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Ingestion,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "derived_artifacts"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :upsert do
      primary? true

      accept [
        :source_version_id,
        :processing_run_id,
        :input_sha256,
        :output_sha256,
        :processor_name,
        :processor_version,
        :config_hash,
        :output_kind,
        :object_key,
        :media_type,
        :quality_measurements
      ]

      upsert? true
      upsert_identity :unique_processor_output
      upsert_fields []
      return_skipped_upsert? true
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :input_sha256, :string, allow_nil?: false, public?: true
    attribute :output_sha256, :string, allow_nil?: false, public?: true
    attribute :processor_name, :string, allow_nil?: false, public?: true
    attribute :processor_version, :string, allow_nil?: false, public?: true
    attribute :config_hash, :string, allow_nil?: false, public?: true
    attribute :output_kind, :string, allow_nil?: false, public?: true
    attribute :object_key, :string, allow_nil?: false, public?: true
    attribute :media_type, :string, allow_nil?: false, public?: true
    attribute :quality_measurements, :map, allow_nil?: false, public?: true, default: %{}
    timestamps()
  end

  relationships do
    belongs_to :source_version, BrusselsWtf.Ingestion.SourceVersion,
      allow_nil?: false,
      public?: true

    belongs_to :processing_run, BrusselsWtf.Ingestion.ProcessingRun,
      allow_nil?: false,
      public?: true
  end

  identities do
    identity :unique_processor_output, [
      :input_sha256,
      :processor_name,
      :processor_version,
      :config_hash,
      :output_kind
    ]
  end
end
