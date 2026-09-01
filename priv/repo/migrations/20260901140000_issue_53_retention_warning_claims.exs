defmodule BrusselsWtf.Repo.Migrations.Issue53RetentionWarningClaims do
  use Ecto.Migration

  def change do
    alter table(:citizen_retention_warnings) do
      add :claim_token, :uuid
      add :lease_expires_at, :utc_datetime_usec
    end

    create constraint(:citizen_retention_warnings, :retention_warning_claim_consistency,
             check:
               "(delivery_status = 'claimed') = (claim_token IS NOT NULL AND lease_expires_at IS NOT NULL)"
           )
  end
end
