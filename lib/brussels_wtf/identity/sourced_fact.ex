defmodule BrusselsWtf.Identity.SourcedFact do
  @moduledoc "An immutable typed and time-bounded fact backed by explicit evidence."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Identity,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "sourced_facts"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :subject_type,
        :subject_id,
        :object_type,
        :object_id,
        :object_label,
        :kind,
        :effective_from,
        :effective_to,
        :source_version_id,
        :authoritative_url,
        :source_authority,
        :evidence_kind,
        :evidence_excerpt,
        :evidence_location,
        :supersedes_id,
        :mandate_declaration
      ]

      upsert? true
      upsert_identity :unique_evidence_fact
      upsert_fields []
      change BrusselsWtf.Identity.Changes.ValidateSourcedFact
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :subject_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:legal_entity, :person]
    end

    attribute :subject_id, :uuid, allow_nil?: false, public?: true

    attribute :object_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:legal_entity, :person, :commune, :contract, :office, :other]
    end

    attribute :object_id, :uuid, public?: true
    attribute :object_label, :string, public?: true

    attribute :kind, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :management,
                    :ownership,
                    :public_mandate,
                    :contract,
                    :donation,
                    :declared_interest,
                    :office_holding
                  ]
    end

    attribute :effective_from, :date, public?: true
    attribute :effective_to, :date, public?: true
    attribute :authoritative_url, :string, public?: true

    attribute :source_authority, :atom do
      public? true
      constraints one_of: [:municipal_decision, :municipal_declaration]
    end

    attribute :evidence_kind, :atom, allow_nil?: false, public?: true
    attribute :evidence_excerpt, :string, allow_nil?: false, public?: true
    attribute :evidence_location, :string, allow_nil?: false, public?: true

    attribute :verification_status, :atom do
      allow_nil? false
      public? true
      default :unreviewed
      constraints one_of: [:unreviewed, :verified, :rejected, :superseded]
    end

    attribute :mandate_declaration, :map, public?: false

    attribute :verified_by, :string, public?: true
    attribute :verification_processor_version, :string, public?: true
    attribute :verification_ruleset_version, :string, public?: true
    attribute :verification_config_sha256, :string, public?: true
    attribute :verification_generation, :string, public?: true
    attribute :verification_processing_run_id, :uuid, public?: true
    attribute :verification_artifact_id, :uuid, public?: true
    attribute :verified_at, :utc_datetime_usec, public?: true
    attribute :supersedes_id, :uuid, public?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :source_version, BrusselsWtf.Ingestion.SourceVersion, public?: true

    belongs_to :verification_processing_run, BrusselsWtf.Ingestion.ProcessingRun do
      source_attribute :verification_processing_run_id
      define_attribute? false
      public? true
    end

    belongs_to :verification_artifact, BrusselsWtf.Ingestion.DerivedArtifact do
      source_attribute :verification_artifact_id
      define_attribute? false
      public? true
    end

    belongs_to :supersedes, __MODULE__ do
      source_attribute :supersedes_id
      define_attribute? false
      public? true
    end

    has_one :superseded_by, __MODULE__ do
      destination_attribute :supersedes_id
      public? true
    end
  end

  identities do
    identity :unique_evidence_fact, [
      :subject_type,
      :subject_id,
      :object_type,
      :object_id,
      :object_label,
      :kind,
      :effective_from,
      :effective_to,
      :source_version_id,
      :authoritative_url,
      :source_authority,
      :evidence_kind,
      :evidence_excerpt,
      :evidence_location,
      :supersedes_id
    ] do
      nils_distinct? false
    end
  end
end
