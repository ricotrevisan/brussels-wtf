defmodule BrusselsWtf.Repo.Migrations.UncappedCoverageLedgerAndCreditChecks do
  @moduledoc """
  ADR 0007: a coverage month may have no app-side limit (NULL), and a call in such a
  month settles at its actual cost even above its estimate. Limited months still
  refuse a cost above its reservation in `CoverageBudget.reconcile/2`. Adds the
  provider credit checks that alert Rico and resume stranded pages.
  """

  use Ecto.Migration

  def up do
    alter table(:coverage_budgets) do
      modify :hard_limit_cents, :bigint, null: true
    end

    drop constraint(:coverage_reservations, :coverage_reservations_valid_costs)

    create constraint(:coverage_reservations, :coverage_reservations_valid_costs,
             check:
               "retry > 0 AND estimated_cost_cents > 0 AND reserved_cents = estimated_cost_cents AND (final_cost_cents IS NULL OR final_cost_cents >= 0) AND (charged_cents IS NULL OR charged_cents >= 0)"
           )

    create table(:provider_credit_checks, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :provider, :text, null: false
      add :trigger, :text, null: false
      add :level, :text, null: false
      add :notified_level, :text, null: false
      add :key_remaining_cents, :bigint
      add :account_remaining_cents, :bigint
      add :resumed_pages, :bigint, null: false, default: 0

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end
  end

  def down do
    drop table(:provider_credit_checks)

    drop constraint(:coverage_reservations, :coverage_reservations_valid_costs)

    create constraint(:coverage_reservations, :coverage_reservations_valid_costs,
             check:
               "retry > 0 AND estimated_cost_cents > 0 AND reserved_cents = estimated_cost_cents AND (final_cost_cents IS NULL OR (final_cost_cents >= 0 AND final_cost_cents <= reserved_cents)) AND (charged_cents IS NULL OR (charged_cents >= 0 AND charged_cents <= reserved_cents))"
           )

    alter table(:coverage_budgets) do
      modify :hard_limit_cents, :bigint, null: false
    end
  end
end
