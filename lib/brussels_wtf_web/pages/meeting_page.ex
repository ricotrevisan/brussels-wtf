defmodule BrusselsWtfWeb.MeetingPage do
  use BrusselsWtfWeb, :dstar_page

  alias BrusselsWtf.Council

  @impl Dstar.Page
  def mount(conn, %{"commune" => commune, "municipal_id" => municipal_id} = params) do
    locale = BrusselsWtfWeb.Locale.resolve(params)

    case Council.get_published_meeting_page(commune, municipal_id) do
      {:ok, page} ->
        variant =
          Enum.find(page.locale_variants, &(&1.locale == locale)) ||
            List.first(page.locale_variants)

        assign(conn,
          page_title: variant.title,
          html_lang: locale,
          meeting_page: page,
          variant: variant,
          locale: locale
        )

      {:error, _} ->
        conn
        |> Plug.Conn.put_status(404)
        |> Phoenix.Controller.put_view(html: BrusselsWtfWeb.ErrorHTML)
        |> Phoenix.Controller.render(:"404")
    end
  end

  @impl Dstar.Page
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-3xl px-4 py-10 text-base-content">
      <p class="text-sm">
        <a href={~p"/"} class="underline underline-offset-2">brussels.wtf</a>
      </p>

      <p class="mt-6 text-sm text-base-content/70">
        {@meeting_page.council_meeting.commune.name} · {Calendar.strftime(
          @meeting_page.council_meeting.scheduled_on,
          "%d %B %Y"
        )}
      </p>

      <h1 class="mt-2 text-3xl font-semibold tracking-tight">{@variant.title}</h1>

      <p class="mt-3 text-sm">
        <span class="font-medium">{procedural_label(@meeting_page.procedural_state)}</span>
        <%= for label <- provenance_labels(@variant.provenance) do %>
          · <span>{label}</span>
        <% end %>
      </p>

      <p class="mt-6 max-w-prose leading-7">{@variant.summary}</p>

      <p class="mt-8 text-sm">
        Source:
        <a href={@meeting_page.citation_url} class="underline underline-offset-2">
          {@meeting_page.citation_url}
        </a>
      </p>

      <p class="mt-8 text-sm text-base-content/70">Rico Trevisan</p>
    </main>
    """
  end

  defp procedural_label(:proposal), do: "Proposal"
  defp procedural_label(:unknown), do: "Unknown outcome"
  defp procedural_label(:decision), do: "Decision"

  defp provenance_labels(values) do
    Enum.map(values, fn
      :ai_generated -> "AI-generated"
      :machine_translated -> "machine-translated"
      :human_reviewed -> "human-reviewed"
    end)
  end
end
