defmodule BrusselsWtf.Repo.Migrations.Issue53CollectionTransferIntegrity do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE citizen_follows ADD CONSTRAINT citizen_follows_citizen_fk FOREIGN KEY (citizen_id) REFERENCES citizens(id) ON DELETE CASCADE"

    create constraint(:citizen_follows, :citizen_follows_target_type_check,
             check: "target_type IN ('dossier', 'person', 'legal_entity', 'commune')"
           )

    create constraint(:citizen_feed_updates, :citizen_feed_updates_target_type_check,
             check: "target_type IN ('dossier', 'person', 'legal_entity', 'commune')"
           )

    create constraint(:citizen_feed_updates, :citizen_feed_updates_read_after_insert_check,
             check: "read_at IS NULL OR read_at >= inserted_at"
           )

    execute "DROP TRIGGER IF EXISTS follow_collection_owner_once ON follow_collections"
    execute "DROP FUNCTION IF EXISTS prevent_follow_collection_reassignment()"

    alter table(:follow_collections) do
      add :ownership_kind, :text, null: false, default: "anonymous"

      modify :owner_citizen_id, references(:citizens, type: :uuid, on_delete: :restrict),
        from: :uuid
    end

    execute "UPDATE follow_collections SET ownership_kind='registered' WHERE owner_citizen_id IS NOT NULL"

    create constraint(:follow_collections, :follow_collections_ownership_kind_check,
             check: "ownership_kind IN ('anonymous', 'registered')"
           )

    execute """
    CREATE FUNCTION enforce_follow_collection_ownership() RETURNS trigger AS $$
    BEGIN
      IF NEW.ownership_kind = 'anonymous' AND NEW.owner_citizen_id IS NOT NULL THEN
        RAISE EXCEPTION 'anonymous collection cannot have a registered owner';
      END IF;
      IF NEW.ownership_kind = 'registered' AND NEW.owner_citizen_id IS NULL THEN
        RAISE EXCEPTION 'registered collection requires an owner';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute "CREATE CONSTRAINT TRIGGER follow_collection_ownership_check AFTER INSERT OR UPDATE ON follow_collections DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION enforce_follow_collection_ownership()"

    execute "ALTER TABLE follow_collection_grants ADD CONSTRAINT follow_collection_grants_collection_fk FOREIGN KEY (collection_id) REFERENCES follow_collections(id) ON DELETE CASCADE"

    execute "ALTER TABLE follow_collection_grants ADD CONSTRAINT follow_collection_grants_citizen_fk FOREIGN KEY (citizen_id) REFERENCES citizens(id) ON DELETE CASCADE"

    execute """
    CREATE FUNCTION reject_owner_collection_grant() RETURNS trigger AS $$
    BEGIN
      IF EXISTS (SELECT 1 FROM follow_collections c WHERE c.id=NEW.collection_id AND c.owner_citizen_id=NEW.citizen_id) THEN
        RAISE EXCEPTION 'collection owner cannot grant view to self';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute "CREATE TRIGGER follow_collection_grant_not_owner BEFORE INSERT OR UPDATE ON follow_collection_grants FOR EACH ROW EXECUTE FUNCTION reject_owner_collection_grant()"

    create table(:follow_collection_transfer_offers, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("uuid_generate_v7()")

      add :collection_id, references(:follow_collections, type: :uuid, on_delete: :delete_all),
        null: false

      add :from_citizen_id, references(:citizens, type: :uuid, on_delete: :restrict), null: false
      add :to_citizen_id, references(:citizens, type: :uuid, on_delete: :restrict), null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :accepted_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:follow_collection_transfer_offers, [:token_hash])

    create unique_index(:follow_collection_transfer_offers, [:collection_id],
             where: "accepted_at IS NULL AND cancelled_at IS NULL",
             name: :follow_collection_transfer_offers_one_active_index
           )

    create constraint(:follow_collection_transfer_offers, :transfer_offer_distinct_citizens,
             check: "from_citizen_id <> to_citizen_id"
           )

    create constraint(:follow_collection_transfer_offers, :transfer_offer_single_resolution,
             check: "accepted_at IS NULL OR cancelled_at IS NULL"
           )
  end

  def down do
    drop table(:follow_collection_transfer_offers)
    execute "DROP TRIGGER IF EXISTS follow_collection_grant_not_owner ON follow_collection_grants"
    execute "DROP FUNCTION IF EXISTS reject_owner_collection_grant()"

    execute "ALTER TABLE follow_collection_grants DROP CONSTRAINT IF EXISTS follow_collection_grants_collection_fk"

    execute "ALTER TABLE follow_collection_grants DROP CONSTRAINT IF EXISTS follow_collection_grants_citizen_fk"

    execute "DROP TRIGGER IF EXISTS follow_collection_ownership_check ON follow_collections"
    execute "DROP FUNCTION IF EXISTS enforce_follow_collection_ownership()"
    drop constraint(:follow_collections, :follow_collections_ownership_kind_check)
    alter table(:follow_collections), do: remove(:ownership_kind)
  end
end
