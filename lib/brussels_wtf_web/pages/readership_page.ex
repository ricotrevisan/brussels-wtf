defmodule BrusselsWtfWeb.ReadershipPage do
  @moduledoc "Read-only reader totals behind the review login."

  use BrusselsWtfWeb, :dstar_page

  alias BrusselsWtf.Readership

  @window_days 30

  @impl Dstar.Page
  def mount(conn, _params) do
    first_day = Date.add(BrusselsWtfWeb.MeetingTime.today(), 1 - @window_days)

    rows =
      Readership.list_page_view_counts_since!(first_day,
        actor: conn.assigns.current_review_actor
      )

    assign(conn,
      page_title: "Reader totals · brussels.wtf",
      window_days: @window_days,
      total: rows |> Enum.map(& &1.count) |> Enum.sum(),
      tables: [
        %{
          id: "by-day",
          title: "By day",
          heading: "Day",
          rows: totals(rows, &Date.to_iso8601(&1.day), :label_desc)
        },
        %{
          id: "by-route",
          title: "By route",
          heading: "Route pattern",
          rows: totals(rows, & &1.route_pattern, :count_desc)
        },
        %{
          id: "by-locale",
          title: "By language",
          heading: "Language",
          rows: totals(rows, & &1.locale, :count_desc)
        },
        %{
          id: "by-referrer",
          title: "By referrer",
          heading: "Referrer host",
          rows: totals(rows, & &1.referrer_host, :count_desc)
        }
      ]
    )
  end

  @impl Dstar.Page
  def render(assigns) do
    ~H"""
    <header class="border-b border-base-300">
      <div class="mx-auto max-w-6xl px-4 py-4">
        <a href="/review" class="font-semibold">brussels.wtf review</a>
      </div>
    </header>

    <main class="mx-auto max-w-6xl px-4 py-8">
      <h1 class="text-3xl font-semibold">Reader totals</h1>
      <p class="mt-2 text-base-content/70">
        {@total} page views in the last {@window_days} days. Daily totals only; obvious bots are excluded.
        “direct” means no usable outside referrer; “other” folds hosts past the daily cap.
      </p>

      <div class="mt-6 grid gap-8 md:grid-cols-2">
        <section :for={table <- @tables} id={table.id} class="min-w-0">
          <h2 class="text-lg font-semibold">{table.title}</h2>
          <p :if={table.rows == []} class="mt-2 text-base-content/70">No page views yet.</p>
          <div :if={table.rows != []} class="mt-2 overflow-x-auto">
            <table class="table table-sm w-full">
              <thead>
                <tr>
                  <th scope="col">{table.heading}</th>
                  <th scope="col" class="text-right">Views</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{label, count} <- table.rows}>
                  <td class="break-all">{label}</td>
                  <td class="text-right tabular-nums">{count}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </main>
    """
  end

  defp totals(rows, label, order) do
    rows
    |> Enum.group_by(label, & &1.count)
    |> Enum.map(fn {key, counts} -> {key, Enum.sum(counts)} end)
    |> sort(order)
  end

  defp sort(rows, :label_desc), do: Enum.sort_by(rows, &elem(&1, 0), :desc)
  defp sort(rows, :count_desc), do: Enum.sort_by(rows, fn {label, count} -> {-count, label} end)
end
