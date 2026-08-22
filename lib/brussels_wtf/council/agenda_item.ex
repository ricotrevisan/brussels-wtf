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

      change {BrusselsWtf.Council.Changes.SetAgendaItemContinuity, mode: :authoritative}
      validate present(:current_source_version_id)

      upsert? true
      upsert_identity :unique_item_continuity
      return_skipped_upsert? true

      upsert_fields [
        :item_number,
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

      change {BrusselsWtf.Council.Changes.SetAgendaItemContinuity, mode: :rendered}
      change set_attribute(:current_version_order, "synthetic")

      upsert? true
      upsert_identity :unique_item_continuity
      upsert_fields [:source_wording, :procedural_state, :outcome]
    end

    update :mark_proposed do
      accept []
      change set_attribute(:procedural_state, :proposal)
    end

    update :publish_current_state do
      require_atomic? false
      accept []

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(
          :published_procedural_state,
          changeset.data.procedural_state
        )
        |> Ash.Changeset.force_change_attribute(:published_outcome, changeset.data.outcome)
        |> Ash.Changeset.force_change_attribute(:published?, true)
        |> Ash.Changeset.force_change_attribute(
          :published_item_number,
          changeset.data.item_number
        )
        |> Ash.Changeset.force_change_attribute(
          :published_decision_id,
          changeset.data.current_decision_id
        )
        |> Ash.Changeset.force_change_attribute(
          :published_proposal_id,
          current_proposal_id(changeset.data.proposals, changeset.data.published_proposal_id)
        )
      end
    end

    update :unpublish_current_state do
      accept []
      change set_attribute(:published?, false)
    end

    update :mark_decided do
      require_atomic? false
      accept [:current_decision_id, :outcome]
      validate present(:current_decision_id)

      validate fn changeset, _context ->
        decision_id = Ash.Changeset.get_attribute(changeset, :current_decision_id)
        outcome = Ash.Changeset.get_attribute(changeset, :outcome)

        if is_nil(decision_id) do
          :ok
        else
          decision = BrusselsWtf.Council.get_decision!(decision_id)

          cond do
            decision.agenda_item_id != changeset.data.id ->
              {:error, "current decision must belong to the agenda item"}

            decision.disposition != outcome ->
              {:error, "agenda item outcome must match the decision disposition"}

            true ->
              :ok
          end
        end
      end

      change set_attribute(:procedural_state, :decision)
    end
  end

  defp current_proposal_id(%Ash.NotLoaded{}, published_id), do: published_id

  defp current_proposal_id(proposals, published_id) do
    proposals
    |> Enum.reject(& &1.synthetic)
    |> case do
      [] -> published_id
      candidates -> Enum.max_by(candidates, &proposal_version_order/1).id
    end
  end

  defp proposal_version_order(proposal) do
    proposal.source_version_order || "0:#{proposal.source_version.id}"
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :item_number, :string, allow_nil?: false, public?: true
    attribute :stable_anchor, :string, allow_nil?: false, public?: true
    attribute :authoritative_identifier, :string, public?: true
    attribute :source_wording, :string, allow_nil?: false, public?: true

    attribute :current_version_order, :string do
      allow_nil? false
      public? true
      default ""
    end

    attribute :current_decision_id, :uuid, public?: true
    attribute :published_decision_id, :uuid, public?: true
    attribute :published_proposal_id, :uuid, public?: true
    attribute :published?, :boolean, allow_nil?: false, public?: true, default: false
    attribute :published_item_number, :string, public?: true

    attribute :published_procedural_state, :atom do
      public? true
      constraints one_of: [:proposal, :unknown, :decision]
    end

    attribute :published_outcome, :atom do
      public? true

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

    attribute :continuity_key, :string do
      allow_nil? false
      public? true
    end

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

    belongs_to :decision, BrusselsWtf.Council.Decision do
      source_attribute :current_decision_id
      destination_attribute :id
      define_attribute? false
      public? true
    end

    belongs_to :published_proposal, BrusselsWtf.Council.Proposal do
      source_attribute :published_proposal_id
      destination_attribute :id
      define_attribute? false
      public? true
    end

    belongs_to :published_decision, BrusselsWtf.Council.Decision do
      source_attribute :published_decision_id
      destination_attribute :id
      define_attribute? false
      public? true
    end

    has_many :decisions, BrusselsWtf.Council.Decision
    has_many :coverage_variants, BrusselsWtf.Council.CoverageVariant
    has_many :dossier_links, BrusselsWtf.Council.DossierLink
  end

  identities do
    identity :unique_item_continuity, [:council_meeting_id, :continuity_key]
    identity :unique_anchor, [:council_meeting_id, :stable_anchor]
  end
end
