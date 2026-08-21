defmodule BrusselsWtf.Repo.Migrations.Issue32CostReconciliationFailure do
  @moduledoc "Adds a durable fail-closed cost reconciliation state."

  use Ecto.Migration

  def up do
    drop_if_exists constraint(:coverage_reservations, :coverage_reservations_valid_state)

    alter table(:coverage_reservations) do
      add :reconciliation_failure, :text
    end

    create constraint(:coverage_reservations, :coverage_reservations_valid_state,
             check:
               "(status IN ('reserved', 'executing', 'reconciliation_pending') AND charged_cents IS NULL AND settled_at IS NULL AND reconciliation_failure IS NULL) OR (status = 'settled' AND charged_cents IS NOT NULL AND settled_at IS NOT NULL AND reconciliation_failure IS NULL) OR (status = 'reconciliation_failed' AND charged_cents IS NULL AND settled_at IS NOT NULL AND reconciliation_failure IS NOT NULL)"
           )
  end

  def down do
    drop_if_exists constraint(:coverage_reservations, :coverage_reservations_valid_state)

    alter table(:coverage_reservations) do
      remove :reconciliation_failure
    end

    create constraint(:coverage_reservations, :coverage_reservations_valid_state,
             check:
               "(status = 'reserved' AND charged_cents IS NULL AND settled_at IS NULL) OR (status = 'settled' AND charged_cents IS NOT NULL AND settled_at IS NOT NULL)"
           )
  end
end
