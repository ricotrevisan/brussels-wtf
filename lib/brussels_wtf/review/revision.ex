defmodule BrusselsWtf.Review.Revision do
  @moduledoc "An append-only reclassification, relink, or correction revision."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Review,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "review_revisions"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true
      accept [:review_case_id, :review_action_id, :kind, :details, :note]
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

    attribute :kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:reclassification, :relink, :correction]]

    attribute :details, :map, allow_nil?: false, public?: true, default: %{}
    attribute :note, :string, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :review_case, BrusselsWtf.Review.Case, allow_nil?: false, public?: true
    belongs_to :review_action, BrusselsWtf.Review.Action, allow_nil?: false, public?: true
  end
end
