defmodule BrusselsWtfWeb.ReviewInboxPage do
  use BrusselsWtfWeb, :dstar_page

  alias BrusselsWtf.Review

  @kinds ~w(acquisition extraction normalization evidence suggestion link_correction publication)
  @statuses ~w(open resolved)

  @impl Dstar.Page
  def mount(conn, params) do
    filters = filters(params)
    actor = conn.assigns.current_review_actor

    assign(conn,
      page_title: "Review inbox · brussels.wtf",
      cases: Review.list_review_cases!(filters, actor: actor),
      filters: params,
      communes: list_communes(),
      kinds: @kinds,
      statuses: @statuses
    )
  end

  @impl Dstar.Page
  def render(assigns) do
    ~H"""
    <header class="border-b border-base-300">
      <div class="mx-auto flex max-w-6xl items-center justify-between px-4 py-4">
        <a href="/review" class="font-semibold">brussels.wtf review</a>
        <form method="post" action="/review/session">
          <input type="hidden" name="_method" value="delete" />
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <button type="submit" class="btn btn-sm">Sign out</button>
        </form>
      </div>
    </header>

    <main class="mx-auto max-w-6xl px-4 py-8">
      <h1 class="text-3xl font-semibold">Review inbox</h1>
      <p class="mt-2 text-base-content/70">
        Actionable domain cases, separate from worker transport state.
      </p>

      <section class="mt-7 border-y border-base-300 py-4">
        <h2 class="text-lg font-semibold">Operational polling</h2>
        <p class="mt-1 text-sm text-base-content/70">
          Poll-now preserves the standing schedule. Backfill is always an explicit operation.
        </p>
        <form method="post" action="/review/polls" class="mt-3 grid gap-3 md:grid-cols-4">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <label>
            Operation
            <select name="operation" class="select select-bordered w-full">
              <option value="poll-now">Poll now</option>
              <option value="backfill">Explicit backfill</option>
            </select>
          </label>
          <label>
            Target type
            <select name="target_type" class="select select-bordered w-full">
              <option value="commune">Commune</option>
              <option value="index">Index</option>
              <option value="meeting">Meeting</option>
              <option value="locator">Locator</option>
            </select>
          </label>
          <label>
            Target ID
            <input
              name="target_id"
              list="poll-target-communes"
              required
              class="input input-bordered w-full"
              placeholder="Select a commune or paste an ID"
            />
            <datalist id="poll-target-communes">
              <option :for={commune <- @communes} value={commune.id}>{commune.name}</option>
            </datalist>
          </label>
          <button type="submit" class="btn self-end">Queue operation</button>
        </form>
      </section>

      <form
        method="get"
        action="/review"
        class="mt-7 grid gap-3 border-y border-base-300 py-4 md:grid-cols-5"
      >
        <label>
          Kind
          <select name="kind" class="select select-bordered w-full">
            <option value="">All</option>
            <option :for={kind <- @kinds} value={kind} selected={@filters["kind"] == kind}>
              {humanize(kind)}
            </option>
          </select>
        </label>
        <label>
          Commune
          <select name="commune" class="select select-bordered w-full">
            <option value="">All</option>
            <option
              :for={commune <- @communes}
              value={commune.id}
              selected={@filters["commune"] == commune.id}
            >
              {commune.name}
            </option>
          </select>
        </label>
        <label>
          Status
          <select name="status" class="select select-bordered w-full">
            <option value="">All</option>
            <option :for={status <- @statuses} value={status} selected={@filters["status"] == status}>
              {humanize(status)}
            </option>
          </select>
        </label>
        <label>
          Generation
          <input name="generation" value={@filters["generation"]} class="input input-bordered w-full" />
        </label>
        <label>
          Age
          <select name="age" class="select select-bordered w-full">
            <option value="">Any</option>
            <option
              :for={{days, label} <- [{1, "Last day"}, {7, "Last 7 days"}, {30, "Last 30 days"}]}
              value={days}
              selected={@filters["age"] == to_string(days)}
            >
              {label}
            </option>
          </select>
        </label>
        <button type="submit" class="btn md:col-span-5 md:justify-self-start">Apply filters</button>
      </form>

      <p :if={@cases == []} class="mt-8">No review cases match these filters.</p>
      <div :if={@cases != []} class="mt-6 overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>Case</th><th>Commune</th><th>Affected record</th><th>Generation</th><th>Urgency</th><th>
                Status / disposition
              </th><th>Age</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={review_case <- @cases}>
              <td>
                <a class="font-medium underline" href={"/review/cases/#{review_case.id}"}>{review_case.summary}</a><br /><span class="text-sm">{humanize(
                  review_case.kind
                )}</span>
              </td>
              <td>{commune_name(review_case)}</td>
              <td>
                <span>{review_case.affected_record_type}</span><br /><code class="text-xs">{review_case.affected_record_id}</code>
              </td>
              <td><code>{review_case.processing_generation}</code></td>
              <td>{humanize(review_case.urgency)}</td>
              <td>
                {humanize(review_case.status)}<br /><span class="text-sm">{humanize(
                  review_case.disposition
                )}</span>
              </td>
              <td>{age(review_case.inserted_at)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </main>
    """
  end

  defp filters(params) do
    %{}
    |> put_allowed(:kind, params["kind"], @kinds)
    |> put_uuid(:commune_id, params["commune"])
    |> put_allowed(:status, params["status"], @statuses)
    |> put_string(:generation, params["generation"])
    |> put_age(params["age"])
  end

  defp put_allowed(filters, key, value, allowed) do
    if value in allowed do
      Map.put(filters, key, String.to_existing_atom(value))
    else
      filters
    end
  end

  defp put_uuid(filters, key, value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> Map.put(filters, key, uuid)
      :error -> filters
    end
  end

  defp put_string(filters, _key, value) when value in [nil, ""], do: filters
  defp put_string(filters, key, value), do: Map.put(filters, key, value)

  defp put_age(filters, value) when value in ["1", "7", "30"],
    do: Map.put(filters, :age_days, String.to_integer(value))

  defp put_age(filters, _value), do: filters

  defp list_communes do
    BrusselsWtf.Ingestion.Commune
    |> Ash.read!(domain: BrusselsWtf.Ingestion)
    |> Enum.sort_by(& &1.name)
  end

  defp commune_name(%{commune: %Ash.NotLoaded{}}), do: "—"
  defp commune_name(%{commune: nil}), do: "—"
  defp commune_name(%{commune: commune}), do: commune.name

  defp humanize(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp age(inserted_at),
    do: "#{max(DateTime.diff(BrusselsWtf.Clock.utc_now(), inserted_at, :hour), 0)}h"
end
