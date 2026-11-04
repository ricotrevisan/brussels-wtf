defmodule BrusselsWtf.Readership do
  @moduledoc """
  Cookieless first-party page view counts: daily totals only.

  A row holds a calendar day, a route pattern, a locale, a referrer host and a
  count. Nothing about an individual request is stored.
  """

  use Ash.Domain, otp_app: :brussels_wtf

  alias BrusselsWtf.Readership.PageViewCount

  @direct "direct"
  @other "other"
  @referrer_hosts_per_day 200

  resources do
    resource PageViewCount do
      define :add_page_views, action: :add
      define :list_page_view_counts_since, action: :since, args: [:first_day]
      define :list_counts_for_referrer_cap, action: :referrer_hosts_on_day, args: [:day]
    end
  end

  def direct_referrer, do: @direct
  def referrer_hosts_per_day, do: @referrer_hosts_per_day

  @doc """
  Adds `count` views to one daily bucket.

  The Referer header is reader-controlled, so distinct hosts are capped per day
  to keep the table bounded. A host counted earlier that day keeps its row.
  """
  def record_page_views({day, route_pattern, locale, referrer_host}, count) do
    add_page_views(
      %{
        day: day,
        route_pattern: route_pattern,
        locale: locale,
        referrer_host: capped_referrer_host(day, referrer_host),
        count: count
      },
      authorize?: false
    )
    |> case do
      {:ok, _row} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp capped_referrer_host(_day, @direct), do: @direct

  defp capped_referrer_host(day, host) do
    known =
      list_counts_for_referrer_cap!(day, authorize?: false)
      |> MapSet.new(& &1.referrer_host)
      |> MapSet.difference(MapSet.new([@direct, @other]))

    cond do
      MapSet.member?(known, host) -> host
      MapSet.size(known) < @referrer_hosts_per_day -> host
      true -> @other
    end
  end
end
