defmodule BrusselsWtf.CBE.Index.Release do
  @moduledoc false
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.CBE.Index,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "cbe_index_releases"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :stage do
      accept [:sha256, :manifest, :projection_version]
      upsert? true
      upsert_identity :archive
      upsert_fields []
    end

    update :advance do
      accept [:progress, :progress_hashes, :completed_files, :state]
      require_atomic? false

      change fn changeset, _ ->
        if changeset.data.state == :ready do
          Ash.Changeset.add_error(changeset, "ready index releases are immutable")
        else
          changeset
        end
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :sha256, :string, allow_nil?: false, sensitive?: true
    attribute :manifest, :map, allow_nil?: false, sensitive?: true
    attribute :projection_version, :integer, allow_nil?: false

    attribute :state, :atom,
      allow_nil?: false,
      default: :staging,
      constraints: [one_of: [:staging, :ready]]

    attribute :progress, :map, allow_nil?: false, default: %{}
    attribute :progress_hashes, :map, allow_nil?: false, default: %{}, sensitive?: true
    attribute :completed_files, {:array, :string}, allow_nil?: false, default: []
    create_timestamp :inserted_at
  end

  identities do
    identity :archive, [:sha256]
  end
end
