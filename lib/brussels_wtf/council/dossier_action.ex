defmodule BrusselsWtf.Council.DossierAction do
  @moduledoc "An append-only record of an authorized dossier revision."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "dossier_actions"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :review_case_id,
        :subject_id,
        :subject_type,
        :action,
        :note,
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
    attribute :subject_id, :uuid, allow_nil?: false, public?: true
    attribute :subject_type, :string, allow_nil?: false, public?: true

    attribute :action, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:confirm_link, :remove_link, :merge, :split, :relink]
    end

    attribute :note, :string, allow_nil?: false, public?: true
    attribute :details, :map, allow_nil?: false, public?: true, default: %{}
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :review_case, BrusselsWtf.Review.Case, public?: true
  end
end
