defmodule BrusselsWtf.Repo.Migrations.CreateFollowCollections do
  use Ecto.Migration

  def change do
    create table(:follow_collections, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :view_token, :text, null: false
      add :management_secret_hash, :binary, null: false
      add :visibility, :text, null: false, default: "unlisted"
      add :title, :text, null: false
      add :last_used_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:follow_collections, [:view_token])
    create unique_index(:follow_collections, [:management_secret_hash])

    create table(:follow_collection_members, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :collection_id, references(:follow_collections, type: :uuid, on_delete: :delete_all),
        null: false

      add :target_type, :text, null: false
      add :target_identifier, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:follow_collection_members, [
             :collection_id,
             :target_type,
             :target_identifier
           ])
  end
end
