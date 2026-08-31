defmodule BrusselsWtf.Repo.Migrations.AllowConsumedFollowManagementCapability do
  use Ecto.Migration

  def change do
    alter table(:follow_collections) do
      modify :management_secret_hash, :binary, null: true, from: {:binary, null: false}
    end
  end
end
