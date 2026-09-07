defmodule BrusselsWtf.Repo.Migrations.Issue52CollectionOwnerOnce do
  use Ecto.Migration

  def up do
    execute """
    CREATE FUNCTION prevent_follow_collection_reassignment() RETURNS trigger AS $$
    BEGIN
      IF OLD.owner_citizen_id IS NOT NULL THEN
        RAISE EXCEPTION 'follow collection owner is immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER follow_collection_owner_once BEFORE UPDATE OF owner_citizen_id ON follow_collections
    FOR EACH ROW EXECUTE FUNCTION prevent_follow_collection_reassignment();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS follow_collection_owner_once ON follow_collections"
    execute "DROP FUNCTION IF EXISTS prevent_follow_collection_reassignment()"
  end
end
