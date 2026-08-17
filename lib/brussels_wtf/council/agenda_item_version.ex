defmodule BrusselsWtf.Council.AgendaItemVersion do
  @moduledoc """
  Immutable normalized wording and agenda membership derived from one source version.
  """

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "agenda_item_versions"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :agenda_item_id,
        :source_version_id,
        :agenda_id,
        :authoritative_identifier,
        :source_wording
      ]

      upsert? true
      upsert_identity :unique_item_source_version
      upsert_fields []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :authoritative_identifier, :string, public?: true
    attribute :source_wording, :string, allow_nil?: false, public?: true
    timestamps()
  end

  relationships do
    belongs_to :agenda_item, BrusselsWtf.Council.AgendaItem, allow_nil?: false, public?: true

    belongs_to :source_version, BrusselsWtf.Ingestion.SourceVersion,
      allow_nil?: false,
      public?: true

    belongs_to :agenda, BrusselsWtf.Council.Agenda, public?: true
  end

  identities do
    identity :unique_item_source_version, [:agenda_item_id, :source_version_id]
  end
end
