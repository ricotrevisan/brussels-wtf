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

    create :upsert do
      primary? true
      accept [:council_meeting_id, :citation_url, :procedural_state]
      upsert? true
      upsert_identity :one_page_per_meeting
    end

    update :publish do
      accept []
      change set_attribute(:publication_status, :published)
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
                    agenda_items: [proposals: [evidence: [:source_version]]]
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
  end

  identities do
    identity :one_page_per_meeting, [:council_meeting_id]
  end
end
