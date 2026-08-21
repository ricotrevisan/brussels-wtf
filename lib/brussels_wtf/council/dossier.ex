defmodule BrusselsWtf.Council.Dossier do
  @moduledoc "A continuing matter that can connect agenda items across meetings."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "dossiers"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:slug, :title, :localized_titles]
    end

    create :upsert do
      primary? true
      accept [:slug, :title, :localized_titles]
      upsert? true
      upsert_identity :unique_slug
    end

    update :retire do
      accept [:retired_into_id]
      require_atomic? false
      change set_attribute(:status, :retired)
    end

    read :by_slug do
      get? true
      argument :slug, :string, allow_nil?: false

      prepare build(
                load: [
                  :retired_into,
                  dossier_links: [
                    agenda_item: [
                      :coverage_variants,
                      published_decision: [evidence: [:source_version]],
                      published_proposal: [:source_version, evidence: [:source_version]],
                      proposals: [:source_version, evidence: [:source_version]],
                      council_meeting: [:commune, meeting_page: [:current_revision]]
                    ]
                  ]
                ]
              )

      filter expr(slug == ^arg(:slug))
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :slug, :string, allow_nil?: false, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :localized_titles, :map, allow_nil?: false, public?: true, default: %{}

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :active
      constraints one_of: [:active, :retired]
    end

    timestamps()
  end

  relationships do
    has_many :dossier_links, BrusselsWtf.Council.DossierLink

    belongs_to :retired_into, __MODULE__ do
      public? true
    end
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
