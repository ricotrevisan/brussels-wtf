defmodule BrusselsWtf.Review.Note do
  @moduledoc "An append-only reviewer note."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Review,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "review_notes"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :add do
      primary? true
      accept [:review_case_id, :body]
      change BrusselsWtf.Review.Changes.RejectSuggestionCaseNote
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
    attribute :body, :string, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :review_case, BrusselsWtf.Review.Case do
      allow_nil? false
      public? true
    end
  end
end
