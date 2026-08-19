defmodule BrusselsWtf.Ingestion.PollScheduleTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Ingestion.PollSchedule

  @now ~U[2026-08-20 12:00:00Z]

  test "meeting locators use six-hour active windows and daily outer windows" do
    assert PollSchedule.next_fetch_at(%{scheduled_on: ~D[2026-07-21], role: :agenda}, @now) ==
             ~U[2026-08-20 18:00:00Z]

    assert PollSchedule.next_fetch_at(%{scheduled_on: ~D[2026-09-19], role: :agenda}, @now) ==
             ~U[2026-08-20 18:00:00Z]

    assert PollSchedule.next_fetch_at(%{scheduled_on: ~D[2026-07-20], role: :agenda}, @now) ==
             ~U[2026-08-21 12:00:00Z]

    assert PollSchedule.next_fetch_at(%{scheduled_on: ~D[2026-09-20], role: :agenda}, @now) ==
             ~U[2026-08-21 12:00:00Z]
  end

  test "polling stops after the historical horizon or thirty stable final-record days" do
    assert PollSchedule.next_fetch_at(%{scheduled_on: ~D[2026-02-21], role: :minutes}, @now) ==
             ~U[2026-08-21 12:00:00Z]

    assert PollSchedule.next_fetch_at(%{scheduled_on: ~D[2026-02-20], role: :minutes}, @now) ==
             :stop

    assert PollSchedule.next_fetch_at(
             %{
               scheduled_on: ~D[2026-07-01],
               role: :minutes,
               last_changed_at: ~U[2026-07-21 12:00:00Z]
             },
             @now
           ) == :stop
  end

  test "delayed-record index and backfill policies stay explicit" do
    assert PollSchedule.next_index_fetch_at(:previous_year, @now) ==
             ~U[2026-08-21 12:00:00Z]

    assert PollSchedule.backfill_schedule() == :explicit_only
  end
end
