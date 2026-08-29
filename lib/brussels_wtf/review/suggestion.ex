defmodule BrusselsWtf.Review.Suggestion do
  @moduledoc """
  A private anonymous ownership or profile-correction suggestion.

  Public intake is available only through `BrusselsWtf.Suggestions`. The body,
  contact, anti-abuse values, and moderation state have no public projection.
  """

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Review,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "review_suggestions"
    repo BrusselsWtf.Repo

    custom_indexes do
      index [:rate_limit_key], name: "review_suggestions_hmac_rate_key_index"
      index [:submission_fingerprint], name: "review_suggestions_hmac_fingerprint_index"
      index [:status, :inserted_at]
      index [:contact_retention_deadline], where: "contact IS NOT NULL"
      index [:body_retention_deadline], where: "body IS NOT NULL"
      index [:anti_abuse_retention_deadline], where: "rate_limit_key IS NOT NULL"
      index [:fingerprint_retention_deadline], where: "submission_fingerprint IS NOT NULL"
    end
  end

  actions do
    defaults [:read]

    create :intake do
      primary? true

      accept [
        :kind,
        :subject_type,
        :subject_id,
        :body,
        :contact,
        :rate_limit_key,
        :submission_fingerprint,
        :body_retention_deadline,
        :contact_retention_deadline,
        :anti_abuse_retention_deadline,
        :fingerprint_retention_deadline,
        :inserted_at
      ]
    end

    update :link_review_case do
      require_atomic? false
      accept [:review_case_id]
    end

    update :decide do
      require_atomic? false

      accept [
        :status,
        :decided_by,
        :decided_at,
        :decision_reason_code,
        :approved_fact_id,
        :contact_retention_deadline
      ]
    end

    update :shorten_contact_retention do
      require_atomic? false
      accept [:contact_retention_deadline]
    end

    update :purge_private_data do
      require_atomic? false
      accept [:body, :contact, :rate_limit_key, :submission_fingerprint, :private_data_purged_at]
    end
  end

  policies do
    policy action_type(:read) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :reviewer)
    end

    policy action_type([:create, :update]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      constraints one_of: [:ownership, :correction]
    end

    attribute :subject_type, :atom do
      allow_nil? false
      constraints one_of: [:legal_entity, :person]
    end

    attribute :subject_id, :uuid, allow_nil?: false

    attribute :body, :string do
      sensitive? true
      constraints min_length: 10, max_length: 10_000
    end

    attribute :contact, :string do
      sensitive? true
      constraints max_length: 500
    end

    attribute :rate_limit_key, :string, sensitive?: true
    attribute :submission_fingerprint, :string, sensitive?: true

    attribute :status, :atom do
      allow_nil? false
      default :pending
      constraints one_of: [:pending, :rejected, :approved]
    end

    attribute :decided_by, :string
    attribute :decided_at, :utc_datetime_usec
    attribute :decision_reason_code, :string
    attribute :body_retention_deadline, :utc_datetime_usec, allow_nil?: false
    attribute :contact_retention_deadline, :utc_datetime_usec, allow_nil?: false
    attribute :anti_abuse_retention_deadline, :utc_datetime_usec, allow_nil?: false
    attribute :fingerprint_retention_deadline, :utc_datetime_usec, allow_nil?: false
    attribute :private_data_purged_at, :utc_datetime_usec
    attribute :inserted_at, :utc_datetime_usec, allow_nil?: false
  end

  relationships do
    belongs_to :review_case, BrusselsWtf.Review.Case, public?: false
    belongs_to :approved_fact, BrusselsWtf.Identity.SourcedFact, public?: false

    has_many :decisions, BrusselsWtf.Review.SuggestionDecision do
      destination_attribute :suggestion_id
      sort inserted_at: :asc
    end
  end
end
