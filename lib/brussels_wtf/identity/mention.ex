defmodule BrusselsWtf.Identity.Mention do
  @moduledoc "A source-backed textual reference that does not itself assert identity or involvement."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Identity,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "mentions"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :occurrence_key,
        :source_version_id,
        :agenda_item_id,
        :text,
        :kind,
        :explicit_identifier,
        :context
      ]

      upsert? true
      upsert_identity :unique_occurrence
      upsert_fields []
    end

    update :resolve_legal_entity do
      require_atomic? false
      accept [:resolved_legal_entity_id]
      change set_attribute(:resolution_status, :resolved)
    end

    update :resolve_person do
      require_atomic? false
      accept [:resolved_person_id]
      change set_attribute(:resolution_status, :resolved)
    end

    update :mark_ambiguous do
      require_atomic? false
      change set_attribute(:resolution_status, :ambiguous)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :occurrence_key, :string, allow_nil?: false, public?: true
    attribute :text, :string, allow_nil?: false, public?: true

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:organization, :person, :unknown]
    end

    attribute :explicit_identifier, :string, public?: true
    attribute :context, :map, allow_nil?: false, public?: true, default: %{}

    attribute :resolution_status, :atom do
      allow_nil? false
      public? true
      default :unresolved
      constraints one_of: [:unresolved, :ambiguous, :resolved]
    end

    timestamps()
  end

  relationships do
    belongs_to :source_version, BrusselsWtf.Ingestion.SourceVersion,
      allow_nil?: false,
      public?: true

    belongs_to :agenda_item, BrusselsWtf.Council.AgendaItem, public?: true
    belongs_to :resolved_legal_entity, BrusselsWtf.Identity.LegalEntity, public?: true
    belongs_to :resolved_person, BrusselsWtf.Identity.Person, public?: true
  end

  identities do
    identity :unique_occurrence, [:occurrence_key]
  end
end
