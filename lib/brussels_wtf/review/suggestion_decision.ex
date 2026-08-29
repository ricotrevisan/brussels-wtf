defmodule BrusselsWtf.Review.SuggestionDecision do
  @moduledoc "An append-only private moderation audit with deadline-driven note redaction."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Review,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "review_suggestion_decisions"
    repo BrusselsWtf.Repo

    custom_indexes do
      index [:note_retention_deadline], where: "note IS NOT NULL"
    end
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :suggestion_id,
        :review_case_id,
        :action,
        :reason_code,
        :note,
        :verified_fact_id,
        :note_retention_deadline,
        :inserted_at
      ]

      change BrusselsWtf.Review.Changes.SetActor
    end

    update :purge_note do
      require_atomic? false
      accept [:note, :note_purged_at]
    end
  end

  policies do
    policy action_type([:read, :create]) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :reviewer)
    end

    policy action(:purge_note) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :actor_id, :string, allow_nil?: false

    attribute :action, :atom do
      allow_nil? false
      constraints one_of: [:reject, :approve]
    end

    attribute :reason_code, :string, allow_nil?: false
    attribute :note, :string, sensitive?: true
    attribute :note_retention_deadline, :utc_datetime_usec, allow_nil?: false
    attribute :note_purged_at, :utc_datetime_usec
    attribute :inserted_at, :utc_datetime_usec, allow_nil?: false
  end

  relationships do
    belongs_to :suggestion, BrusselsWtf.Review.Suggestion, allow_nil?: false
    belongs_to :review_case, BrusselsWtf.Review.Case, allow_nil?: false
    belongs_to :verified_fact, BrusselsWtf.Identity.SourcedFact
  end

  identities do
    identity :one_decision_per_suggestion, [:suggestion_id]
  end
end
