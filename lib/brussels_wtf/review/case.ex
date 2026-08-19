defmodule BrusselsWtf.Review.Case do
  @moduledoc """
  An actionable acquisition, extraction, normalization, evidence, suggestion,
  or link-correction ambiguity, independent from worker transport state.
  """

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Review,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "review_cases"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :open do
      primary? true

      accept [
        :kind,
        :commune_id,
        :affected_record_id,
        :affected_record_type,
        :source_record_id,
        :source_version_id,
        :processing_generation,
        :urgency,
        :summary,
        :extracted_text,
        :normalized_content,
        :quality_measurements,
        :diagnostics,
        :related_evidence
      ]

      upsert? true
      upsert_identity :unique_generation
      upsert_fields []
      return_skipped_upsert? true
    end

    read :inbox do
      argument :kind, :atom do
        constraints one_of: [
                      :acquisition,
                      :extraction,
                      :normalization,
                      :evidence,
                      :suggestion,
                      :link_correction,
                      :publication
                    ]
      end

      argument :commune_id, :uuid

      argument :status, :atom do
        constraints one_of: [:open, :resolved]
      end

      argument :generation, :string
      argument :age_days, :integer, constraints: [min: 1, max: 3650]
      prepare BrusselsWtf.Review.Preparations.FilterInbox
    end

    update :retry do
      require_atomic? false
      argument :note, :string, allow_nil?: false
      argument :processor_name, :string, allow_nil?: false
      argument :processor_version, :string, allow_nil?: false
      argument :config_hash, :string, allow_nil?: false
      argument :details, :map, allow_nil?: false, default: %{}

      change {BrusselsWtf.Review.Changes.AuditAction,
              action: :retry,
              effect: :processing_generation,
              disposition: :retry_requested,
              resolve?: false}
    end

    update :complete_retry do
      require_atomic? false
      change set_attribute(:status, :resolved)
    end

    update :reclassify do
      require_atomic? false
      argument :note, :string, allow_nil?: false

      argument :classification, :atom,
        allow_nil?: false,
        constraints: [
          one_of: [
            :index,
            :agenda,
            :project,
            :supplement,
            :addendum,
            :minutes,
            :register,
            :recording
          ]
        ]

      change {BrusselsWtf.Review.Changes.AuditAction,
              action: :reclassify, effect: :domain_revision, disposition: :reclassified}
    end

    update :relink do
      require_atomic? false
      argument :note, :string, allow_nil?: false
      argument :target_record_id, :uuid, allow_nil?: false

      argument :target_record_type, :atom,
        allow_nil?: false,
        constraints: [one_of: [:council_meeting]]

      change {BrusselsWtf.Review.Changes.AuditAction,
              action: :relink, effect: :domain_revision, disposition: :relinked}
    end

    update :correct do
      require_atomic? false
      argument :note, :string, allow_nil?: false
      argument :corrected_content, :map, allow_nil?: false

      change {BrusselsWtf.Review.Changes.AuditAction,
              action: :correct, effect: :domain_revision, disposition: :corrected}
    end

    update :mark_unsupported do
      require_atomic? false
      argument :note, :string, allow_nil?: false
      argument :reason_code, :string, allow_nil?: false

      change {BrusselsWtf.Review.Changes.AuditAction,
              action: :mark_unsupported, effect: :exclusion, disposition: :unsupported}
    end
  end

  policies do
    policy action(:open) do
      authorize_if always()
    end

    policy action(:complete_retry) do
      authorize_if actor_absent()
    end

    policy action_type(:read) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :reviewer)
    end

    policy action([:retry, :reclassify, :relink, :correct, :mark_unsupported]) do
      authorize_if actor_attribute_equals(:role, :reviewer)
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
                    :suggestion,
                    :link_correction,
                    :publication
                  ]
    end

    attribute :affected_record_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :affected_record_type, :string do
      allow_nil? false
      public? true
      default "unknown"
    end

    attribute :processing_generation, :string do
      allow_nil? false
      public? true
    end

    attribute :urgency, :atom do
      allow_nil? false
      public? true
      default :normal
      constraints one_of: [:low, :normal, :high, :critical]
    end

    attribute :summary, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :open
      constraints one_of: [:open, :resolved]
    end

    attribute :disposition, :atom do
      allow_nil? false
      public? true
      default :open

      constraints one_of: [
                    :open,
                    :retry_requested,
                    :reclassified,
                    :relinked,
                    :corrected,
                    :unsupported
                  ]
    end

    attribute :extracted_text, :string, public?: true
    attribute :normalized_content, :map, public?: true, default: %{}
    attribute :quality_measurements, :map, public?: true, default: %{}
    attribute :diagnostics, :map, public?: true, default: %{}
    attribute :related_evidence, :map, public?: true, default: %{}

    timestamps()
  end

  relationships do
    belongs_to :commune, BrusselsWtf.Ingestion.Commune do
      public? true
    end

    belongs_to :source_record, BrusselsWtf.Ingestion.SourceRecord do
      public? true
    end

    belongs_to :source_version, BrusselsWtf.Ingestion.SourceVersion do
      public? true
    end

    has_many :actions, BrusselsWtf.Review.Action do
      destination_attribute :review_case_id
      sort inserted_at: :asc
    end

    has_many :notes, BrusselsWtf.Review.Note do
      destination_attribute :review_case_id
      sort inserted_at: :asc
    end

    has_many :revisions, BrusselsWtf.Review.Revision do
      destination_attribute :review_case_id
      sort inserted_at: :asc
    end

    has_many :exclusions, BrusselsWtf.Review.Exclusion do
      destination_attribute :review_case_id
      sort inserted_at: :asc
    end
  end

  identities do
    identity :unique_generation, [:kind, :affected_record_id, :processing_generation]
  end
end
