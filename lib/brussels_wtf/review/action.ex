defmodule BrusselsWtf.Review.Action do
  @moduledoc "An append-only record of an authorized review action and its domain effect."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Review,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "review_actions"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true
      accept [:review_case_id, :action, :note, :effect, :disposition, :details]
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

    attribute :action, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:retry, :reclassify, :relink, :correct, :mark_unsupported]
    end

    attribute :effect, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:processing_generation, :domain_revision, :exclusion]
    end

    attribute :disposition, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:retry_requested, :reclassified, :relinked, :corrected, :unsupported]
    end

    attribute :note, :string, allow_nil?: false, public?: true
    attribute :details, :map, allow_nil?: false, public?: true, default: %{}
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :review_case, BrusselsWtf.Review.Case do
      allow_nil? false
      public? true
    end
  end
end
