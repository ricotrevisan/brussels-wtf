defmodule BrusselsWtf.Review.Case do
  @moduledoc """
  An acquisition, extraction, normalization, or evidence ambiguity for review.
  """

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Review,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "review_cases"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :open do
      primary? true
      accept [:kind, :affected_record_id, :processing_generation, :summary]
      upsert? true
      upsert_identity :unique_generation
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :acquisition,
                    :extraction,
                    :normalization,
                    :evidence,
                    :publication
                  ]
    end

    attribute :affected_record_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :processing_generation, :string do
      allow_nil? false
      public? true
    end

    attribute :summary, :string do
      allow_nil? false
      public? true
    end

    attribute :disposition, :atom do
      allow_nil? false
      public? true
      default :open
      constraints one_of: [:open, :resolved]
    end

    timestamps()
  end

  identities do
    identity :unique_generation, [:kind, :affected_record_id, :processing_generation]
  end
end
