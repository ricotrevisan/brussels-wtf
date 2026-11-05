defmodule BrusselsWtf.Council.CoverageLedgerTest do
  @moduledoc "ADR 0007: a month without an app-side limit is a ledger only."
  use BrusselsWtf.DataCase, async: false

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.CoverageBudget

  setup do
    BrusselsWtf.Seeds.PublicTimeline.run!()
    meeting = Council.get_ingested_meeting!("ixelles", "demo-ixelles")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)
    %{page: page, now: BrusselsWtf.Clock.utc_now()}
  end

  defp call(page, key, estimate) do
    %{
      meeting_page_id: page.id,
      publication_input_hash: "sha256:" <> key,
      operation: :canonical_generation,
      locale: "fr",
      provider: "openrouter",
      model: "m",
      retry: 1,
      call_key: key,
      estimated_cost_cents: estimate
    }
  end

  test "an unlimited month admits any estimate and settles above it at the actual cost", ctx do
    assert {:ok, reservation, :new} =
             CoverageBudget.reserve_for_execution(call(ctx.page, "a", 5_000), nil, ctx.now)

    assert {:ok, {:admit, _}} = CoverageBudget.begin_execution(reservation.id)

    assert {:ok, settled} =
             CoverageBudget.reconcile(reservation.id, %{final_cost_cents: 7_000})

    assert {settled.status, settled.charged_cents} == {:settled, 7_000}
    assert {:ok, budget} = CoverageBudget.ensure_month(nil, ctx.now)
    assert {budget.hard_limit_cents, budget.spent_cents, budget.reserved_cents} == {nil, 7_000, 0}
  end

  test "removing the limit turns an existing month into a ledger without losing its spend", ctx do
    assert {:ok, r, :new} =
             CoverageBudget.reserve_for_execution(call(ctx.page, "b", 10), 20, ctx.now)

    assert {:ok, _} = CoverageBudget.begin_execution(r.id)
    assert {:ok, _} = CoverageBudget.reconcile(r.id, %{final_cost_cents: 8})

    assert {:error, :budget_exhausted} =
             CoverageBudget.reserve_for_execution(call(ctx.page, "c", 50), 20, ctx.now)

    assert {:ok, %{hard_limit_cents: nil, spent_cents: 8}} =
             CoverageBudget.ensure_month(nil, ctx.now)

    assert {:ok, _, :new} =
             CoverageBudget.reserve_for_execution(call(ctx.page, "c", 50), nil, ctx.now)
  end

  test "a limited month still refuses a cost above its reservation", ctx do
    assert {:ok, r, :new} =
             CoverageBudget.reserve_for_execution(call(ctx.page, "d", 10), 100, ctx.now)

    assert {:ok, _} = CoverageBudget.begin_execution(r.id)
    assert {:ok, failed} = CoverageBudget.reconcile(r.id, %{final_cost_cents: 11})
    assert failed.status == :reconciliation_failed
  end
end
