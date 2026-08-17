defmodule BrusselsWtf.Council.AgendaItem do
  @moduledoc """
  A meeting-specific matter with an explicit current normalized version and immutable version history.
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

      accept [
        :council_meeting_id,
        :item_number,
        :stable_anchor,
        :authoritative_identifier,
        :source_wording,
        :current_source_version_id,
        :current_version_order,
        :procedural_state,
        :outcome
      ]

      upsert? true
      upsert_identity :unique_item
      return_skipped_upsert? true

      upsert_fields [
        :authoritative_identifier,
        :source_wording,
        :current_source_version_id,
        :current_version_order
      ]

      upsert_condition expr(
                         is_nil(current_version_order) or
                           current_version_order <= upsert_conflict(:current_version_order)
                       )
    end

    create :upsert_rendered do
      accept [
        :council_meeting_id,
        :item_number,
        :stable_anchor,
        :source_wording,
        :procedural_state,
        :outcome
      ]

      upsert? true
      upsert_identity :unique_item
      upsert_fields [:source_wording, :procedural_state, :outcome]
    end

    update :mark_proposed do
      accept []
      change set_attribute(:procedural_state, :proposal)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :item_number, :string, allow_nil?: false, public?: true
    attribute :stable_anchor, :string, allow_nil?: false, public?: true
    attribute :authoritative_identifier, :string, public?: true
    attribute :source_wording, :string, allow_nil?: false, public?: true
    attribute :current_version_order, :string, public?: true

    attribute :procedural_state, :atom do
      allow_nil? false
      public? true
      default :unknown
      constraints one_of: [:proposal, :unknown, :decision]
    end

    attribute :outcome, :atom do
      allow_nil? false
      public? true
      default :unknown

      constraints one_of: [
                    :unknown,
                    :approved,
                    :rejected,
                    :amended,
                    :postponed,
                    :withdrawn,
                    :other
                  ]
    end

    timestamps()
  end

  relationships do
    belongs_to :council_meeting, BrusselsWtf.Council.Meeting, allow_nil?: false, public?: true
    belongs_to :current_source_version, BrusselsWtf.Ingestion.SourceVersion, public?: true
    has_many :versions, BrusselsWtf.Council.AgendaItemVersion
    has_many :proposals, BrusselsWtf.Council.Proposal
    has_one :decision, BrusselsWtf.Council.Decision
    has_many :coverage_variants, BrusselsWtf.Council.CoverageVariant
    has_many :dossier_links, BrusselsWtf.Council.DossierLink
  end

  identities do
    identity :unique_item, [:council_meeting_id, :item_number]
    identity :unique_anchor, [:council_meeting_id, :stable_anchor]
  end
end
