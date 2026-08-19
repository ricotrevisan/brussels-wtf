defmodule BrusselsWtf.Council.Proposal do
  @moduledoc "An action described before the council has made a final decision."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "proposals"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true
      accept [:agenda_item_id, :source_version_id, :source_version_order, :text, :status]
      validate present(:source_version_id)

      upsert? true
      upsert_identity :unique_item_source
      upsert_fields []
    end

    create :upsert_rendered do
      accept [:agenda_item_id, :text, :status, :render_key]
      validate present(:render_key)
      change set_attribute(:synthetic, true)
      upsert? true
      upsert_identity :unique_rendered_item
      upsert_fields [:text, :status, :synthetic]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :text, :string, allow_nil?: false, public?: true
    attribute :render_key, :string, public?: true
    attribute :source_version_order, :string, public?: true
    attribute :synthetic, :boolean, allow_nil?: false, public?: true, default: false

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :proposed
      constraints one_of: [:proposed]
    end

    timestamps()
  end

  relationships do
    belongs_to :agenda_item, BrusselsWtf.Council.AgendaItem, allow_nil?: false, public?: true
    belongs_to :source_version, BrusselsWtf.Ingestion.SourceVersion, public?: true
    has_many :evidence, BrusselsWtf.Council.Evidence
  end

  identities do
    identity :unique_item_source, [:agenda_item_id, :source_version_id]
    identity :unique_rendered_item, [:agenda_item_id, :render_key]
  end
end
