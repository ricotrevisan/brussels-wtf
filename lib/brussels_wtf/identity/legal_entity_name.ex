defmodule BrusselsWtf.Identity.LegalEntityName do
  @moduledoc "A dated registered, abbreviated, or trading name beneath one legal entity."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Identity,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "legal_entity_names"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true
      accept [:legal_entity_id, :cbe_release_id, :name, :kind, :language, :effective_from]
      upsert? true
      upsert_identity :unique_name_observation
      upsert_fields []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:registered, :abbreviated, :trading]
    end

    attribute :language, :string, public?: true
    attribute :effective_from, :date, public?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :legal_entity, BrusselsWtf.Identity.LegalEntity,
      allow_nil?: false,
      public?: true

    belongs_to :cbe_release, BrusselsWtf.Identity.CbeRelease,
      allow_nil?: false,
      public?: true
  end

  identities do
    identity :unique_name_observation, [
      :legal_entity_id,
      :cbe_release_id,
      :name,
      :kind,
      :language,
      :effective_from
    ] do
      nils_distinct? false
    end
  end
end
