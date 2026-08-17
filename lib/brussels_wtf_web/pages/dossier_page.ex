defmodule BrusselsWtfWeb.DossierPage do
  use BrusselsWtfWeb, :dstar_page

  alias BrusselsWtf.Council

  @impl Dstar.Page
  def mount(conn, %{"slug" => slug} = params) do
    locale = BrusselsWtfWeb.Locale.resolve(conn, params)

    case Council.get_dossier(slug) do
      {:ok, dossier} ->
        entries =
          dossier.dossier_links
          |> Enum.flat_map(&entry(&1, locale))
          |> Enum.sort_by(& &1.date, {:asc, Date})

        assign(conn,
          page_title: text(locale, :title) <> ": " <> dossier.title,
          html_lang: locale,
          resource_path: "/dossiers/#{slug}",
          locale: locale,
          dossier: dossier,
          entries: entries
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
    <a href="#content" class="sr-only focus:not-sr-only focus:absolute focus:p-3 focus:bg-base-100">
      {text(@locale, :skip)}
    </a>
    <header class="border-b border-base-300">
      <div class="mx-auto flex max-w-4xl items-center justify-between gap-4 px-4 py-4">
        <a href={"/?lang=" <> @locale} class="font-semibold tracking-wide">brussels.wtf</a>
        <nav aria-label="Language">
          <ul class="flex gap-3 text-sm">
            <li :for={{code, label} <- [{"fr", "FR"}, {"nl", "NL"}, {"en", "EN"}]}>
              <a
                href={"/dossiers/#{@dossier.slug}?lang=#{code}"}
                lang={code}
                hreflang={code}
                aria-current={if code == @locale, do: "page"}
                class="underline underline-offset-2"
              >{label}</a>
            </li>
          </ul>
        </nav>
      </div>
    </header>

    <main id="content" class="mx-auto max-w-4xl px-4 py-8" tabindex="-1">
      <p class="text-sm text-base-content/70">{text(@locale, :dossier)}</p>
      <h1 class="mt-2 text-3xl font-semibold">{text(@locale, :title)}: {@dossier.title}</h1>

      <ol class="mt-8 border-l border-base-300 pl-6">
        <li :for={entry <- @entries} class="relative pb-8">
          <span
            aria-hidden="true"
            class="absolute -left-[1.7rem] top-2 size-3 rounded-full bg-base-content"
          ></span>
          <p class="text-sm text-base-content/70">
            {entry.commune} ·
            <time datetime={Date.to_iso8601(entry.date)}>{Date.to_iso8601(entry.date)}</time>
            · {text(@locale, :item)} {entry.item_number}
          </p>
          <h2 class="mt-2 text-xl font-semibold">
            <a href={entry.href} class="underline underline-offset-3">{entry.title}</a>
          </h2>
          <p class="mt-2">{entry.summary}</p>
          <p :for={evidence <- entry.evidences} class="mt-2 text-sm">
            <a href={evidence.citation_url} rel="external" class="underline underline-offset-2">
              {evidence.source_title}
            </a>
            <span :if={evidence.synthetic} class="block font-medium text-warning">
              {text(@locale, :synthetic_reference)}
            </span>
          </p>
        </li>
      </ol>

      <footer class="mt-8 border-t border-base-300 pt-5 text-sm text-base-content/70">
        {text(@locale, :byline)} Rico Trevisan
      </footer>
    </main>
    """
  end

  defp entry(link, locale) do
    item = link.agenda_item
    meeting = item.council_meeting
    page = loaded_or_nil(meeting.meeting_page)

    if page && page.publication_status == :published do
      variant =
        Enum.find(item.coverage_variants, &(&1.locale == locale)) ||
          unavailable_item_variant(locale)

      decision = loaded_or_nil(item.decision)

      state =
        if decision,
          do: :decision,
          else: if(item.procedural_state == :decision, do: :unknown, else: item.procedural_state)

      [
        %{
          commune: commune_name(locale, meeting.commune.slug, meeting.commune.name),
          date: meeting.scheduled_on,
          item_number: item.item_number,
          title: variant.title,
          summary: summary(variant, state, locale),
          evidences: item.evidences,
          href:
            "/meetings/#{meeting.commune.slug}/#{meeting.municipal_identifier}?lang=#{locale}##{item.stable_anchor}"
        }
      ]
    else
      []
    end
  end

  defp unavailable_item_variant(locale) do
    %{
      title: text(locale, :item_unavailable),
      summary: text(locale, :unavailable),
      proposal_summary: nil,
      decision_summary: nil
    }
  end

  defp summary(variant, :decision, locale),
    do: variant.decision_summary || text(locale, :decision_unavailable)

  defp summary(variant, _state, _locale), do: variant.proposal_summary || variant.summary

  defp loaded_or_nil(%Ash.NotLoaded{}), do: nil
  defp loaded_or_nil(value), do: value

  defp commune_name("fr", "city-of-brussels", _name), do: "Ville de Bruxelles"
  defp commune_name("nl", "city-of-brussels", _name), do: "Stad Brussel"
  defp commune_name("nl", "ixelles", _name), do: "Elsene"
  defp commune_name("nl", "uccle", _name), do: "Ukkel"
  defp commune_name("nl", "forest", _name), do: "Vorst"
  defp commune_name(_locale, _slug, name), do: name

  defp text("fr", :skip), do: "Aller au contenu"
  defp text("fr", :dossier), do: "Dossier en cours"
  defp text("fr", :title), do: "Chronologie du dossier"
  defp text("fr", :item), do: "Point"
  defp text("fr", :unavailable), do: "Contenu indisponible en français"
  defp text("fr", :item_unavailable), do: "Contenu du point indisponible en français"

  defp text("fr", :decision_unavailable),
    do: "Le texte de la décision n’est pas disponible en français."

  defp text("fr", :synthetic_reference),
    do: "Référence de démonstration — ne constitue pas une preuve d’activité communale"

  defp text("fr", :byline), do: "Par"
  defp text("nl", :skip), do: "Naar inhoud"
  defp text("nl", :dossier), do: "Lopend dossier"
  defp text("nl", :title), do: "Dossiertijdlijn"
  defp text("nl", :item), do: "Agendapunt"
  defp text("nl", :unavailable), do: "Inhoud niet beschikbaar in het Nederlands"

  defp text("nl", :item_unavailable),
    do: "Inhoud van het agendapunt niet beschikbaar in het Nederlands"

  defp text("nl", :decision_unavailable),
    do: "De beslissingstekst is niet beschikbaar in het Nederlands."

  defp text("nl", :synthetic_reference),
    do: "Demonstratiereferentie — geen bewijs van gemeentelijke activiteit"

  defp text("nl", :byline), do: "Door"
  defp text(_locale, :skip), do: "Skip to content"
  defp text(_locale, :dossier), do: "Continuing dossier"
  defp text(_locale, :title), do: "Dossier timeline"
  defp text(_locale, :item), do: "Agenda item"
  defp text(_locale, :unavailable), do: "Coverage unavailable in English"
  defp text(_locale, :item_unavailable), do: "Agenda-item coverage unavailable in English"
  defp text(_locale, :decision_unavailable), do: "Decision copy is unavailable in English."

  defp text(_locale, :synthetic_reference),
    do: "Demonstration reference — not evidence of council activity"

  defp text(_locale, :byline), do: "By"
end
