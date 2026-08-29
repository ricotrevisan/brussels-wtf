defmodule BrusselsWtf.Ingestion.ProcessingRunArtifact do
  @moduledoc "Immutable provenance link between one processor generation and a content-addressed artifact."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Ingestion,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "processing_run_artifacts"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :link do
      primary? true
      accept [:processing_run_id, :derived_artifact_id, :role]
      upsert? true
      upsert_identity :unique_run_artifact_role
      upsert_fields []
      return_skipped_upsert? true
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:native_output, :ocr_document, :ocr_output, :relationship_claim]
    end

    timestamps()
  end

  relationships do
    belongs_to :processing_run, BrusselsWtf.Ingestion.ProcessingRun,
      allow_nil?: false,
      public?: true

    belongs_to :derived_artifact, BrusselsWtf.Ingestion.DerivedArtifact,
      allow_nil?: false,
      public?: true
  end

  identities do
    identity :unique_run_artifact_role, [:processing_run_id, :derived_artifact_id, :role]
  end
end
