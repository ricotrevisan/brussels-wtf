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
      accept [:agenda_item_id, :source_version_id, :text, :status]
      upsert? true
      upsert_identity :unique_item_source
      upsert_fields []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :text, :string, allow_nil?: false, public?: true

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

    belongs_to :source_version, BrusselsWtf.Ingestion.SourceVersion,
      allow_nil?: false,
      public?: true

    has_many :evidence, BrusselsWtf.Council.Evidence
  end

  identities do
    identity :unique_item_source, [:agenda_item_id, :source_version_id]
  end
end
