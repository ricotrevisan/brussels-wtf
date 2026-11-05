defmodule BrusselsWtfWeb.PublicDate do
  @moduledoc "Reader-facing dates in the page language. Machine values stay in `<time datetime>`."

  @months %{
    "en" =>
      ~w(January February March April May June July August September October November December),
    "fr" =>
      ~w(janvier février mars avril mai juin juillet août septembre octobre novembre décembre),
    "nl" =>
      ~w(januari februari maart april mei juni juli augustus september oktober november december)
  }

  def long(%Date{} = date, locale) do
    month = @months |> Map.get(locale, @months["en"]) |> Enum.at(date.month - 1)
    "#{date.day} #{month} #{date.year}"
  end

  def long_datetime(%DateTime{} = datetime, locale),
    do: long(DateTime.to_date(datetime), locale) <> Calendar.strftime(datetime, ", %H:%M UTC")
end
