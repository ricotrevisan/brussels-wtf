defmodule BrusselsWtf.Ingestion.PollSchedule do
  @moduledoc """
  Data-driven locator polling policy.

  Cron starts only fixed index polls. Each locator persists the timestamp
  returned here so PostgreSQL, rather than dynamic cron entries, owns due work.
  """

  @active_interval_seconds 6 * 60 * 60
  @daily_interval_seconds 24 * 60 * 60
  @active_window_days 30
  @historical_horizon_days 180
  @stable_final_days 30
  @final_roles [:minutes, :register]

  @spec next_fetch_at(map(), DateTime.t()) :: DateTime.t() | :stop
  def next_fetch_at(locator, %DateTime{} = now) do
    cond do
      beyond_historical_horizon?(locator, now) ->
        :stop

      stable_final_record?(locator, now) ->
        :stop

      active_window?(locator, now) ->
        DateTime.add(now, @active_interval_seconds, :second)

      true ->
        DateTime.add(now, @daily_interval_seconds, :second)
    end
  end

  @spec next_index_fetch_at(:previous_year, DateTime.t()) :: DateTime.t()
  def next_index_fetch_at(:previous_year, %DateTime{} = now),
    do: DateTime.add(now, @daily_interval_seconds, :second)

  @spec backfill_schedule() :: :explicit_only
  def backfill_schedule, do: :explicit_only

  defp active_window?(%{scheduled_on: %Date{} = scheduled_on}, now) do
    abs(Date.diff(scheduled_on, DateTime.to_date(now))) <= @active_window_days
  end

  defp active_window?(_locator, _now), do: false

  defp beyond_historical_horizon?(%{scheduled_on: %Date{} = scheduled_on}, now) do
    Date.diff(DateTime.to_date(now), scheduled_on) > @historical_horizon_days
  end

  defp beyond_historical_horizon?(_locator, _now), do: false

  defp stable_final_record?(%{role: role, last_changed_at: %DateTime{} = changed_at}, now)
       when role in @final_roles do
    DateTime.diff(now, changed_at, :second) >= @stable_final_days * @daily_interval_seconds
  end

  defp stable_final_record?(_locator, _now), do: false
end
