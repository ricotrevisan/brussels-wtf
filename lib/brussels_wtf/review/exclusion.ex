defmodule BrusselsWtf.Review.Exclusion do
  @moduledoc "An append-only exclusion that prevents unsupported input from retrying forever."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Review,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "review_exclusions"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :review_case_id,
        :review_action_id,
        :affected_record_id,
        :processing_generation,
        :reason,
        :details
      ]

      change BrusselsWtf.Review.Changes.SetActor
    end
  end

  policies do
    policy action_type([:read, :create]) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :reviewer)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :actor_id, :string, allow_nil?: false, public?: true
    attribute :affected_record_id, :uuid, allow_nil?: false, public?: true
    attribute :processing_generation, :string, allow_nil?: false, public?: true
    attribute :reason, :string, allow_nil?: false, public?: true
    attribute :details, :map, allow_nil?: false, public?: true, default: %{}
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :review_case, BrusselsWtf.Review.Case, allow_nil?: false, public?: true
    belongs_to :review_action, BrusselsWtf.Review.Action, allow_nil?: false, public?: true
  end
end
