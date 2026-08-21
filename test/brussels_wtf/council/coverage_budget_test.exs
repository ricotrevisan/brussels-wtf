defmodule BrusselsWtf.Council.CoverageBudgetTest do
  use BrusselsWtf.DataCase, async: false

  alias BrusselsWtf.Council.CoverageBudget

  setup do
    BrusselsWtf.Seeds.PublicTimeline.run!()

    meeting = BrusselsWtf.Council.get_ingested_meeting!("ixelles", "demo-ixelles")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
    %{page: page}
  end

  test "one persisted hard limit owns each UTC calendar month" do
    now = ~U[2026-08-21 10:00:00Z]

    assert {:ok, budget} = CoverageBudget.ensure_month(1_000, now)
    assert budget.period_start == ~D[2026-08-01]
    assert budget.hard_limit_cents == 1_000
    assert budget.reserved_cents == 0
    assert budget.spent_cents == 0

    assert {:ok, same_budget} = CoverageBudget.ensure_month(1_000, now)
    assert same_budget.id == budget.id

    assert {:error, :budget_limit_mismatch} = CoverageBudget.ensure_month(2_000, now)
  end

  test "a reservation atomically admits a call within the monthly limit", %{page: page} do
    now = ~U[2026-08-21 10:00:00Z]

    assert {:ok, reservation} =
             CoverageBudget.reserve(reservation_attrs(page, "canonical-1", 40), 100, now)

    assert reservation.status == :reserved
    assert reservation.reserved_cents == 40
    assert reservation.estimated_cost_cents == 40

    assert {:error, :budget_exhausted} =
             CoverageBudget.reserve(reservation_attrs(page, "translation-1", 70), 100, now)

    assert {:ok, budget} = CoverageBudget.ensure_month(100, now)
    assert budget.reserved_cents == 40
    assert budget.spent_cents == 0
  end

  test "the same call key reuses one reservation without reserving twice", %{page: page} do
    now = ~U[2026-08-21 10:00:00Z]
    attrs = reservation_attrs(page, "same-call", 40)

    assert {:ok, first, :new} = CoverageBudget.reserve_for_execution(attrs, 100, now)
    assert {:ok, repeated, :existing} = CoverageBudget.reserve_for_execution(attrs, 100, now)
    assert repeated.id == first.id

    assert {:ok, budget} = CoverageBudget.ensure_month(100, now)
    assert budget.reserved_cents == 40
  end

  test "reconciliation releases the reservation and retains usage and final cost", %{page: page} do
    now = ~U[2026-08-21 10:00:00Z]

    assert {:ok, reservation} =
             CoverageBudget.reserve(reservation_attrs(page, "canonical-settle", 40), 100, now)

    assert {:ok, settled} =
             CoverageBudget.reconcile(reservation.id, %{
               final_cost_cents: 25,
               input_usage: %{"tokens" => 120},
               output_usage: %{"tokens" => 30},
               settled_at: ~U[2026-08-21 10:00:01Z]
             })

    assert settled.status == :settled
    assert settled.final_cost_cents == 25
    assert settled.charged_cents == 25
    assert settled.input_usage == %{"tokens" => 120}
    assert settled.output_usage == %{"tokens" => 30}

    assert {:ok, budget} = CoverageBudget.ensure_month(100, now)
    assert budget.reserved_cents == 0
    assert budget.spent_cents == 25
  end

  test "unknown final cost charges the conservative reservation exactly once", %{page: page} do
    now = ~U[2026-08-21 10:00:00Z]

    assert {:ok, reservation} =
             CoverageBudget.reserve(reservation_attrs(page, "unknown-cost", 40), 100, now)

    assert {:ok, first} =
             CoverageBudget.reconcile(reservation.id, %{
               input_usage: %{"tokens" => 100},
               output_usage: %{"tokens" => 20},
               settled_at: ~U[2026-08-21 10:00:01Z]
             })

    assert first.final_cost_cents == nil
    assert first.charged_cents == 40

    assert {:ok, repeated} =
             CoverageBudget.reconcile(reservation.id, %{
               final_cost_cents: 1,
               settled_at: ~U[2026-08-21 10:00:02Z]
             })

    assert repeated.id == first.id
    assert repeated.final_cost_cents == nil
    assert repeated.charged_cents == 40

    assert {:ok, budget} = CoverageBudget.ensure_month(100, now)
    assert budget.reserved_cents == 0
    assert budget.spent_cents == 40
  end

  test "concurrent calls cannot reserve beyond the hard monthly limit", %{page: page} do
    now = ~U[2026-08-21 10:00:00Z]

    results =
      1..10
      |> Task.async_stream(
        fn number ->
          CoverageBudget.reserve(
            reservation_attrs(page, "concurrent-#{number}", 30),
            100,
            now
          )
        end,
        max_concurrency: 10,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _reservation}, &1)) == 3
    assert Enum.count(results, &(&1 == {:error, :budget_exhausted})) == 7

    assert {:ok, budget} = CoverageBudget.ensure_month(100, now)
    assert budget.reserved_cents == 90
    assert budget.spent_cents == 0
  end

  test "a poisoned month stays closed while concurrent reservations settle", %{page: page} do
    now = ~U[2026-08-21 10:00:00Z]

    assert {:ok, first} =
             CoverageBudget.reserve(reservation_attrs(page, "poison-first", 40), 100, now)

    assert {:ok, second} =
             CoverageBudget.reserve(reservation_attrs(page, "poison-second", 40), 100, now)

    assert {:ok, failed} =
             CoverageBudget.reconcile(first.id, %{
               final_cost_cents: 70,
               output_usage: %{"cost_cents" => 70},
               settled_at: ~U[2026-08-21 10:00:01Z]
             })

    assert failed.status == :reconciliation_failed

    assert {:ok, settled} =
             CoverageBudget.reconcile(second.id, %{
               final_cost_cents: 15,
               output_usage: %{"cost_cents" => 15},
               settled_at: ~U[2026-08-21 10:00:02Z]
             })

    assert settled.status == :settled
    assert {:ok, budget} = CoverageBudget.ensure_month(100, now)
    assert budget.poisoned_at != nil
    assert budget.spent_cents == 15
    assert budget.reserved_cents == 85

    assert {:error, :budget_exhausted} =
             CoverageBudget.reserve(reservation_attrs(page, "after-poison", 1), 100, now)
  end

  test "reconciliation retry exhaustion persists domain failure and poisons the month", %{
    page: page
  } do
    now = ~U[2026-08-21 10:00:00Z]

    assert {:ok, reservation} =
             CoverageBudget.reserve(reservation_attrs(page, "retry-terminal", 20), 100, now)

    run =
      BrusselsWtf.Council.record_coverage_run!(%{
        meeting_page_id: page.id,
        operation: :canonical_generation,
        locale: "fr",
        input_hash: "sha256:retry-input",
        output_hash: "sha256:retry-output",
        processor_name: "paid-test",
        processor_version: "1",
        config_hash: "sha256:paid-test",
        provider_category: "paid_test",
        model: "paid-model",
        method: :ai_generation,
        status: :succeeded,
        input: %{},
        output: %{},
        usage: %{"cost_cents" => -1}
      })

    job = %Oban.Job{
      attempt: 6,
      args: %{
        "reservation_id" => reservation.id,
        "coverage_run_id" => run.id,
        "usage" => %{"cost_cents" => -1}
      }
    }

    assert :ok = BrusselsWtf.Workers.ReconcileCoverageCost.perform(job)

    failed =
      Ash.get!(BrusselsWtf.Council.CoverageReservation, reservation.id,
        domain: BrusselsWtf.Council
      )

    assert failed.status == :reconciliation_failed
    assert failed.coverage_run_id == run.id
    assert failed.reconciliation_failure == "retry_exhausted:invalid_final_cost"

    assert {:ok, budget} = CoverageBudget.ensure_month(100, now)
    assert budget.poisoned_at != nil
    assert budget.reserved_cents == 100
  end

  defp reservation_attrs(page, call_key, estimated_cost_cents) do
    %{
      meeting_page_id: page.id,
      publication_input_hash: "sha256:publication-input",
      operation: :canonical_generation,
      locale: "fr",
      provider: "paid-test-provider",
      model: "paid-test-model",
      retry: 1,
      call_key: call_key,
      estimated_cost_cents: estimated_cost_cents
    }
  end
end
