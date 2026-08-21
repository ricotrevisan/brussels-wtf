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
        :evidence_kind,
        :evidence_excerpt,
        :evidence_location,
        :verification_status,
        :verified_by,
        :verified_at,
        :supersedes_id
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
    attribute :evidence_kind, :atom, allow_nil?: false, public?: true
    attribute :evidence_excerpt, :string, allow_nil?: false, public?: true
    attribute :evidence_location, :string, allow_nil?: false, public?: true

    attribute :verification_status, :atom do
      allow_nil? false
      public? true
      default :candidate
      constraints one_of: [:candidate, :verified, :rejected, :superseded]
    end

    attribute :verified_by, :string, public?: true
    attribute :verified_at, :utc_datetime_usec, public?: true
    attribute :supersedes_id, :uuid, public?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :source_version, BrusselsWtf.Ingestion.SourceVersion, public?: true
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
      :evidence_kind,
      :evidence_location
    ] do
      nils_distinct? false
    end
  end
end
