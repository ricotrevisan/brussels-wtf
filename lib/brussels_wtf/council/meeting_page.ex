defmodule BrusselsWtf.Council.MeetingPage do
  @moduledoc """
  The publication unit for one council meeting.
  """

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "meeting_pages"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    action :generate_coverage, :atom do
      argument :meeting_id, :uuid, allow_nil?: false
      argument :attempt, :integer, allow_nil?: false
      argument :max_attempts, :integer, allow_nil?: false

      run fn input, _context ->
        case BrusselsWtf.Council.Publication.generate_and_publish(
               input.arguments.meeting_id,
               input.arguments.attempt,
               input.arguments.max_attempts
             ) do
          :ok -> {:ok, :ok}
          {:error, _reason} = error -> error
        end
      end
    end

    action :evaluate_publication_gate, :map do
      argument :meeting_page_id, :uuid, allow_nil?: false
      argument :expected_input_hash, :string, allow_nil?: false

      run fn input, _context ->
        {:ok,
         BrusselsWtf.Council.PublicationGate.evaluate(
           input.arguments.meeting_page_id,
           input.arguments.expected_input_hash
         )}
      end
    end

    create :upsert do
      primary? true
      accept [:council_meeting_id, :citation_url, :procedural_state, :revision_published_at]
      upsert? true
      upsert_identity :one_page_per_meeting
    end

    update :stage_revision do
      change set_attribute(:publication_status, :draft)
    end

    update :record_gate_failure do
      accept [:publication_input_hash, :last_gate_failures, :gate_checked_at]
    end

    update :publish do
      require_atomic? false
      argument :gate_input_hash, :string, allow_nil?: false

      accept [
        :revision_published_at,
        :publication_input_hash,
        :last_gate_failures,
        :gate_checked_at,
        :current_revision_id
      ]

      validate fn changeset, _context ->
        gate_input_hash = Ash.Changeset.get_argument(changeset, :gate_input_hash)
        publication_input_hash = Ash.Changeset.get_attribute(changeset, :publication_input_hash)
        revision_id = Ash.Changeset.get_attribute(changeset, :current_revision_id)

        gate_ready? =
          BrusselsWtf.Council.PublicationGate.evaluate(changeset.data.id, gate_input_hash).ready?

        revision_ready? =
          is_binary(revision_id) and gate_input_hash == publication_input_hash and
            BrusselsWtf.Council.PublicationRevision.valid_for_publish?(
              revision_id,
              changeset.data.id,
              gate_input_hash,
              Ash.Changeset.get_attribute(changeset, :revision_published_at)
            )

        if gate_ready? and revision_ready?,
          do: :ok,
          else: {:error, "publication gate and matching revision are required"}
      end

      change set_attribute(:publication_status, :published)
    end

    read :published do
      prepare build(
                load: [
                  :locale_variants,
                  council_meeting: [
                    :commune,
                    agenda_items: [
                      :coverage_variants,
                      decision: [:source_version, evidence: [:source_version]],
                      published_decision: [:source_version, evidence: [:source_version]],
                      published_proposal: [:source_version, evidence: [:source_version]],
                      proposals: [:source_version, evidence: [:source_version]],
                      dossier_links: [:dossier]
                    ]
                  ]
                ]
              )

      filter expr(publication_status == :published)
    end

    read :published_by_identity do
      get? true

      argument :commune_slug, :string, allow_nil?: false
      argument :municipal_identifier, :string, allow_nil?: false

      prepare build(
                load: [
                  :locale_variants,
                  council_meeting: [
                    :commune,
                    agenda_items: [
                      :coverage_variants,
                      decision: [:source_version, evidence: [:source_version]],
                      published_decision: [:source_version, evidence: [:source_version]],
                      published_proposal: [:source_version, evidence: [:source_version]],
                      proposals: [:source_version, evidence: [:source_version]],
                      dossier_links: [:dossier]
                    ]
                  ]
                ]
              )

      filter expr(
               publication_status == :published and
                 council_meeting.municipal_identifier == ^arg(:municipal_identifier) and
                 council_meeting.commune.slug == ^arg(:commune_slug)
             )
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :publication_status, :atom do
      allow_nil? false
      public? true
      default :draft
      constraints one_of: [:draft, :published]
    end

    attribute :citation_url, :string do
      allow_nil? false
      public? true
    end

    attribute :revision_published_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :publication_input_hash, :string, public?: true

    attribute :last_gate_failures, {:array, :map} do
      allow_nil? false
      public? true
      default []
    end

    attribute :gate_checked_at, :utc_datetime_usec, public?: true

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

    has_many :locale_variants, BrusselsWtf.Council.LocaleVariant
    has_many :coverage_runs, BrusselsWtf.Council.CoverageRun
    has_many :publication_revisions, BrusselsWtf.Council.PublicationRevision

    belongs_to :current_revision, BrusselsWtf.Council.PublicationRevision, public?: true
  end

  identities do
    identity :one_page_per_meeting, [:council_meeting_id]
  end
end
