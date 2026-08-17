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
      accept [:agenda_item_id, :dossier_id]
      upsert? true
      upsert_identity :unique_link
    end
  end

  attributes do
    uuid_v7_primary_key :id
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
