defmodule BrusselsWtf.Council.Evidence do
  @moduledoc "Claim-specific evidence or an explicitly marked synthetic rendering reference."

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

    create :upsert_reference do
      accept [
        :proposal_id,
        :claim,
        :excerpt,
        :location,
        :citation_url,
        :retrieved_at,
        :source_title,
        :render_key,
        :synthetic
      ]

      upsert? true
      upsert_identity :unique_rendered_reference

      upsert_fields [
        :excerpt,
        :location,
        :citation_url,
        :retrieved_at,
        :source_title,
        :synthetic
      ]
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
    attribute :source_title, :string, public?: true
    attribute :render_key, :string, public?: true
    attribute :synthetic, :boolean, allow_nil?: false, public?: true, default: false
    timestamps()
  end

  relationships do
    belongs_to :proposal, BrusselsWtf.Council.Proposal, allow_nil?: false, public?: true
    belongs_to :source_version, BrusselsWtf.Ingestion.SourceVersion, public?: true
  end

  identities do
    identity :unique_proposal_source_claim, [:proposal_id, :source_version_id, :claim]
    identity :unique_rendered_reference, [:proposal_id, :render_key]
  end
end
