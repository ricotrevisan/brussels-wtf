defmodule BrusselsWtf.Council.CoverageBatch do
  @moduledoc "An authenticated bounded allowlist queued for coverage generation."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "coverage_batches"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      public? false
      primary? true
      accept [:requester_id, :meeting_ids, :status, :generation_kind]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :requester_id, :string, allow_nil?: false, public?: true
    attribute :meeting_ids, {:array, :uuid}, allow_nil?: false, public?: true

    attribute :generation_kind, :atom do
      allow_nil? false
      public? true
      default :backfill
      constraints one_of: [:backfill]
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :queued
      constraints one_of: [:queued]
    end

    timestamps()
  end
end
