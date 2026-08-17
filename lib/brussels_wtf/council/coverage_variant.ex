defmodule BrusselsWtf.Council.CoverageVariant do
  @moduledoc "A complete localized representation of one meeting-specific coverage item."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "coverage_variants"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :upsert do
      primary? true

      accept [
        :agenda_item_id,
        :locale,
        :title,
        :summary,
        :proposal_summary,
        :decision_summary,
        :provenance
      ]

      upsert? true
      upsert_identity :unique_locale
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :locale, :string, allow_nil?: false, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :summary, :string, allow_nil?: false, public?: true
    attribute :proposal_summary, :string, public?: true
    attribute :decision_summary, :string, public?: true

    attribute :provenance, {:array, :atom} do
      allow_nil? false
      public? true
      default []
      constraints items: [one_of: [:ai_generated, :machine_translated, :human_reviewed]]
    end

    timestamps()
  end

  relationships do
    belongs_to :agenda_item, BrusselsWtf.Council.AgendaItem, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_locale, [:agenda_item_id, :locale]
  end
end
