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

    create :upsert do
      primary? true
      accept [:slug, :title]
      upsert? true
      upsert_identity :unique_slug
    end

    read :by_slug do
      get? true
      argument :slug, :string, allow_nil?: false

      prepare build(
                load: [
                  dossier_links: [
                    agenda_item: [
                      :decision,
                      :coverage_variants,
                      proposals: [evidence: [:source_version]],
                      council_meeting: [:commune, meeting_page: [:locale_variants]]
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
    timestamps()
  end

  relationships do
    has_many :dossier_links, BrusselsWtf.Council.DossierLink
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
