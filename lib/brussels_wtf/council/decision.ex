defmodule BrusselsWtf.Council.Decision do
  @moduledoc "An explicitly sourced final disposition."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "decisions"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :upsert do
      primary? true
      accept [:agenda_item_id, :disposition, :statement]
      upsert? true
      upsert_identity :one_per_item
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :disposition, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:approved, :rejected, :amended, :postponed, :withdrawn, :other]
    end

    attribute :statement, :string, allow_nil?: false, public?: true
    timestamps()
  end

  relationships do
    belongs_to :agenda_item, BrusselsWtf.Council.AgendaItem, allow_nil?: false, public?: true
  end

  identities do
    identity :one_per_item, [:agenda_item_id]
  end
end
