defmodule BrusselsWtfWeb.MeetingTime do
  @moduledoc "Calendar presentation of meetings, independent of their documented outcome."

  def today do
    BrusselsWtf.Clock.utc_now()
    |> DateTime.shift_zone!("Europe/Brussels", Tzdata.TimeZoneDatabase)
    |> DateTime.to_date()
  end

  def past?(date), do: Date.compare(date, today()) == :lt

  def group(:decision, _date), do: :decided
  def group(:proposal, date), do: if(past?(date), do: :awaiting, else: :coming)
  def group(_state, _date), do: :awaiting
end
