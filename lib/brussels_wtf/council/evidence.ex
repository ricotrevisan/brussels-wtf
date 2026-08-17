defmodule BrusselsWtf.Council.Evidence do
  @moduledoc "Claim-specific authoritative evidence for a normalized fact."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "claim_evidence"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :proposal_id,
        :source_version_id,
        :claim,
        :excerpt,
        :location,
        :citation_url,
        :retrieved_at,
        :applicable_from,
        :applicable_until
      ]

      upsert? true
      upsert_identity :unique_proposal_source_claim
      upsert_fields []
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :claim, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:proposal]
    end

    attribute :excerpt, :string, allow_nil?: false, public?: true
    attribute :location, :string, allow_nil?: false, public?: true
    attribute :citation_url, :string, allow_nil?: false, public?: true
    attribute :retrieved_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :applicable_from, :date, public?: true
    attribute :applicable_until, :date, public?: true
    timestamps()
  end

  relationships do
    belongs_to :proposal, BrusselsWtf.Council.Proposal, allow_nil?: false, public?: true

    belongs_to :source_version, BrusselsWtf.Ingestion.SourceVersion,
      allow_nil?: false,
      public?: true
  end

  identities do
    identity :unique_proposal_source_claim, [:proposal_id, :source_version_id, :claim]
  end
end
