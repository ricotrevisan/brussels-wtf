defmodule BrusselsWtf.Council.DossierMatchExclusion do
  @moduledoc "A durable rejected agenda-item and dossier association."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "dossier_match_exclusions"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :agenda_item_id,
        :dossier_id,
        :dossier_action_id,
        :matcher_name,
        :matcher_version,
        :match_features,
        :reason
      ]

      change BrusselsWtf.Review.Changes.SetActor
      upsert? true
      upsert_identity :unique_association
      upsert_fields []
      return_skipped_upsert? true
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
    attribute :matcher_name, :string, allow_nil?: false, public?: true
    attribute :matcher_version, :string, allow_nil?: false, public?: true
    attribute :match_features, :map, allow_nil?: false, public?: true, default: %{}
    attribute :reason, :string, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :agenda_item, BrusselsWtf.Council.AgendaItem, allow_nil?: false, public?: true
    belongs_to :dossier, BrusselsWtf.Council.Dossier, allow_nil?: false, public?: true

    belongs_to :dossier_action, BrusselsWtf.Council.DossierAction,
      allow_nil?: false,
      public?: true
  end

  identities do
    identity :unique_association, [:agenda_item_id, :dossier_id]
  end
end
