defmodule BrusselsWtf.Identity.EnrichmentRequest do
  @moduledoc "One asynchronous CBE enrichment generation for an explicitly identified mention."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Identity,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "enrichment_requests"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :queue do
      primary? true
      accept [:mention_id, :enterprise_number, :generation]
      upsert? true
      upsert_identity :unique_generation
      upsert_fields []
      return_skipped_upsert? true
    end

    update :complete do
      require_atomic? false
      accept [:status, :legal_entity_id, :cbe_release_id, :diagnostics, :completed_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :enterprise_number, :string, allow_nil?: false, public?: true
    attribute :generation, :string, allow_nil?: false, public?: true, default: "automatic"

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :queued
      constraints one_of: [:queued, :succeeded, :failed]
    end

    attribute :diagnostics, :map, allow_nil?: false, public?: true, default: %{}
    attribute :completed_at, :utc_datetime_usec, public?: true
    timestamps()
  end

  relationships do
    belongs_to :mention, BrusselsWtf.Identity.Mention, allow_nil?: false, public?: true
    belongs_to :legal_entity, BrusselsWtf.Identity.LegalEntity, public?: true
    belongs_to :cbe_release, BrusselsWtf.Identity.CbeRelease, public?: true
  end

  identities do
    identity :unique_generation, [:mention_id, :enterprise_number, :generation]
  end
end
