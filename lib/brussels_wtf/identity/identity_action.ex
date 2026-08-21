defmodule BrusselsWtf.Identity.IdentityAction do
  @moduledoc "Append-only audit history for reviewer person merge and split decisions."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "identity_actions"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true
      accept [:action, :subject_person_id, :target_person_id, :created_person_id, :note, :details]
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
      constraints one_of: [:merge, :split]
    end

    attribute :subject_person_id, :uuid, allow_nil?: false, public?: true
    attribute :target_person_id, :uuid, public?: true
    attribute :created_person_id, :uuid, public?: true
    attribute :note, :string, allow_nil?: false, public?: true
    attribute :details, :map, allow_nil?: false, public?: true, default: %{}
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :subject_person, BrusselsWtf.Identity.Person do
      source_attribute :subject_person_id
      define_attribute? false
      allow_nil? false
      public? true
    end

    belongs_to :target_person, BrusselsWtf.Identity.Person do
      source_attribute :target_person_id
      define_attribute? false
      public? true
    end

    belongs_to :created_person, BrusselsWtf.Identity.Person do
      source_attribute :created_person_id
      define_attribute? false
      public? true
    end
  end
end
