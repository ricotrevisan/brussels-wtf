defmodule BrusselsWtf.Identity.CbeRelease do
  @moduledoc "One immutable CBE Open Data release used as enrichment evidence."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Identity,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "cbe_releases"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true
      accept [:release_key, :published_on, :sha256, :source_kind]
      upsert? true
      upsert_identity :unique_release
      upsert_fields []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :release_key, :string, allow_nil?: false, public?: true
    attribute :published_on, :date, allow_nil?: false, public?: true
    attribute :sha256, :string, allow_nil?: false, public?: true

    attribute :source_kind, :atom do
      allow_nil? false
      public? true
      default :open_data
      constraints one_of: [:open_data]
    end

    create_timestamp :inserted_at
  end

  identities do
    identity :unique_release, [:release_key, :sha256]
  end
end
