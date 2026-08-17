defmodule BrusselsWtf.Council.AgendaItem do
  @moduledoc """
  A meeting-specific matter. Outcome stays unknown until a final record exists.
  """

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "agenda_items"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :upsert do
      primary? true
      accept [:council_meeting_id, :item_number, :source_wording, :procedural_state]
      upsert? true
      upsert_identity :unique_item
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :item_number, :string do
      allow_nil? false
      public? true
    end

    attribute :source_wording, :string do
      allow_nil? false
      public? true
    end

    attribute :procedural_state, :atom do
      allow_nil? false
      public? true
      default :proposal
      constraints one_of: [:proposal, :unknown, :decision]
    end

    timestamps()
  end

  relationships do
    belongs_to :council_meeting, BrusselsWtf.Council.Meeting do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_item, [:council_meeting_id, :item_number]
  end
end
