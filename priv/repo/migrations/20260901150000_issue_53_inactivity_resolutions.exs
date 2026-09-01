defmodule BrusselsWtf.Repo.Migrations.Issue53InactivityOwnershipResolutions do
  use Ecto.Migration

  def change do
    create table(:citizen_inactivity_ownership_resolutions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :citizen_id, references(:citizens, type: :uuid, on_delete: :delete_all), null: false

      add :collection_id, references(:follow_collections, type: :uuid, on_delete: :delete_all),
        null: false

      add :inactivity_cycle_at, :utc_datetime_usec, null: false
      add :choice, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :citizen_inactivity_ownership_resolutions,
             [:citizen_id, :collection_id, :inactivity_cycle_at],
             name: :citizen_inactivity_resolution_cycle_index
           )

    create constraint(:citizen_inactivity_ownership_resolutions, :valid_choice,
             check: "choice IN ('delete', 'transfer')"
           )
  end
end
