defmodule BrusselsWtf.Repo.Migrations.Issue53DeletionLifecycle do
  use Ecto.Migration

  def up do
    alter table(:citizen_deletion_audits) do
      add :reason, :text, null: false, default: "citizen_request"
    end
  end

  def down do
    alter table(:citizen_deletion_audits), do: remove(:reason)
  end
end
