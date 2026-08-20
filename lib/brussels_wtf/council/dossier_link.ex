defmodule BrusselsWtf.Council.DossierLink do
  @moduledoc "An evidence-supported link from an agenda item to a continuing dossier."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "dossier_links"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :upsert do
      primary? true

      accept [
        :agenda_item_id,
        :dossier_id,
        :match_method,
        :confidence,
        :matcher_name,
        :matcher_version,
        :match_features,
        :processing_generation,
        :status,
        :disposition
      ]

      upsert? true
      upsert_identity :unique_link

      upsert_fields [
        :match_method,
        :confidence,
        :matcher_name,
        :matcher_version,
        :match_features,
        :processing_generation,
        :status,
        :disposition,
        :updated_at
      ]
    end

    update :confirm do
      require_atomic? false
      change set_attribute(:status, :active)
      change set_attribute(:disposition, :confirmed)
    end

    update :remove do
      require_atomic? false
      change set_attribute(:status, :removed)
      change set_attribute(:disposition, :removed)
    end

    update :move do
      require_atomic? false
      accept [:dossier_id]
      change set_attribute(:status, :active)
      change set_attribute(:disposition, :confirmed)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :match_method, :atom do
      allow_nil? false
      public? true
      default :editorial
      constraints one_of: [:authoritative_identifier, :automated, :editorial]
    end

    attribute :confidence, :float, allow_nil?: false, public?: true, default: 1.0
    attribute :matcher_name, :string, allow_nil?: false, public?: true, default: "editorial"
    attribute :matcher_version, :string, allow_nil?: false, public?: true, default: "1"
    attribute :match_features, :map, allow_nil?: false, public?: true, default: %{}

    attribute :processing_generation, :string,
      allow_nil?: false,
      public?: true,
      default: "editorial"

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :active
      constraints one_of: [:active, :removed]
    end

    attribute :disposition, :atom do
      allow_nil? false
      public? true
      default :confirmed
      constraints one_of: [:unreviewed, :confirmed, :removed]
    end

    timestamps()
  end

  relationships do
    belongs_to :agenda_item, BrusselsWtf.Council.AgendaItem, allow_nil?: false, public?: true
    belongs_to :dossier, BrusselsWtf.Council.Dossier, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_link, [:agenda_item_id, :dossier_id]
  end
end
