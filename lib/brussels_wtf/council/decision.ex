defmodule BrusselsWtf.Council.Decision do
  @moduledoc "A final disposition tied to the authoritative source version that documents it."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "decisions"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :agenda_item_id,
        :source_version_id,
        :interpretation_key,
        :disposition,
        :statement,
        :votes_for,
        :votes_against,
        :abstentions
      ]

      validate present(:source_version_id)

      validate fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :source_version_id) do
          nil ->
            :ok

          source_version_id ->
            source =
              source_version_id
              |> BrusselsWtf.Ingestion.get_source_version!()
              |> Ash.load!(:source_record)

            if source.source_record.role in [:minutes, :register],
              do: :ok,
              else: {:error, "authoritative final minutes or register are required"}
        end
      end

      upsert? true
      upsert_identity :one_per_item_source
      upsert_fields []
    end

    create :upsert_rendered do
      accept [
        :agenda_item_id,
        :render_key,
        :disposition,
        :statement,
        :votes_for,
        :votes_against,
        :abstentions
      ]

      validate present(:render_key)
      change set_attribute(:synthetic, true)
      upsert? true
      upsert_identity :one_rendered_per_item
      upsert_fields [:disposition, :statement, :votes_for, :votes_against, :abstentions]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :disposition, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:approved, :rejected, :amended, :postponed, :withdrawn, :other]
    end

    attribute :statement, :string, allow_nil?: false, public?: true
    attribute :interpretation_key, :string, allow_nil?: false, default: "legacy", public?: true
    attribute :render_key, :string, public?: true
    attribute :votes_for, :integer, public?: true, constraints: [min: 0]
    attribute :votes_against, :integer, public?: true, constraints: [min: 0]
    attribute :abstentions, :integer, public?: true, constraints: [min: 0]
    attribute :synthetic, :boolean, allow_nil?: false, public?: true, default: false
    timestamps()
  end

  relationships do
    belongs_to :agenda_item, BrusselsWtf.Council.AgendaItem, allow_nil?: false, public?: true
    belongs_to :source_version, BrusselsWtf.Ingestion.SourceVersion, public?: true
    has_many :evidence, BrusselsWtf.Council.Evidence
  end

  identities do
    identity :one_per_item_source, [:agenda_item_id, :source_version_id, :interpretation_key]
    identity :one_rendered_per_item, [:agenda_item_id, :render_key]
  end
end
