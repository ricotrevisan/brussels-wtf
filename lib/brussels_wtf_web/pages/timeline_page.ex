defmodule BrusselsWtfWeb.TimelinePage do
  use BrusselsWtfWeb, :dstar_page

  alias BrusselsWtf.Council

  @communes [
    {"ixelles", "Ixelles"},
    {"uccle", "Uccle"},
    {"forest", "Forest"},
    {"city-of-brussels", "City of Brussels"}
  ]
  @slugs Enum.map(@communes, &elem(&1, 0))
  @real_corpus_meeting_count 8

  @impl Dstar.Page
  def mount(conn, params) do
    locale = BrusselsWtfWeb.Locale.resolve(conn, params)
    selected = selected_communes(params)

    pages =
      Council.list_published_meeting_pages!()
      |> prefer_real_corpus()
      |> Enum.filter(&(&1.council_meeting.commune.slug in selected))

    entries =
      pages
      |> Enum.flat_map(fn page ->
        page.council_meeting.agenda_items
        |> Enum.filter(& &1.published?)
        |> Enum.map(&entry(page, &1, locale))
      end)

    q = String.slice(params["q"] || "", 0, 200)
    show = selected_sections(params)
    needle = String.downcase(q)

    matching =
      Enum.filter(entries, fn entry ->
        needle == "" or String.contains?(String.downcase(entry.search_text), needle)
      end)

    assign(conn,
      page_title: "brussels.wtf",
      html_lang: locale,
      resource_path: "/",
      locale: locale,
      communes:
        Enum.map(@communes, fn {slug, name} -> {slug, commune_name(locale, slug, name)} end),
      selected_communes: selected,
      q: q,
      show: show,
      coming: matching |> Enum.filter(&(&1.state == :proposal)) |> newest_first(),
      previously: matching |> Enum.filter(&(&1.state in [:decision, :unknown])) |> newest_first()
    )
  end

  defp prefer_real_corpus(pages) do
    real_pages = Enum.filter(pages, &real_page?/1)
    if length(real_pages) >= @real_corpus_meeting_count, do: real_pages, else: pages
  end

  defp real_page?(page) do
    Enum.any?(page.council_meeting.agenda_items, fn item ->
      proposal = loaded_or_nil(item.published_proposal)
      decision = loaded_or_nil(item.published_decision)
      real_proposal? = proposal && not proposal.synthetic
      real_decision? = decision && Enum.any?(decision.evidence, &(not &1.synthetic))
      real_proposal? || real_decision?
    end)
  end

  @impl Dstar.Page
  def render(assigns) do
    ~H"""
    <a href="#content" class="sr-only focus:not-sr-only focus:absolute focus:p-3 focus:bg-base-100">
      {text(@locale, :skip)}
    </a>
    <header class="border-b border-base-300">
      <div class="mx-auto flex max-w-6xl items-center justify-between gap-4 px-4 py-4">
        <a href={~p"/"} class="font-semibold tracking-wide">brussels.wtf</a>
        <.language_nav locale={@locale} path="/" />
      </div>
    </header>

    <main id="content" class="mx-auto max-w-6xl px-4 py-8 text-base-content" tabindex="-1">
      <div class="grid gap-8 md:grid-cols-[15rem_minmax(0,1fr)]">
        <aside class="md:sticky md:top-4 md:self-start">
          <h1 class="text-xl font-semibold tracking-tight">{text(@locale, :title)}</h1>
          <p class="mt-2 text-sm text-base-content/70">{text(@locale, :intro)}</p>
          <form
            :for={{slug, _name} <- @communes}
            id={"follow-commune-#{slug}"}
            method="post"
            action="/citizen/feed/follows"
          >
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <input type="hidden" name="target_type" value="commune" />
            <input type="hidden" name="target_identifier" value={slug} />
          </form>
          <form method="get" action="/" data-reader-communes class="mt-5 space-y-4">
            <input type="hidden" name="lang" value={@locale} />
            <input type="hidden" name="communes_submitted" value="1" />
            <label class="block text-sm font-medium">
              {text(@locale, :search)}
              <input type="search" name="q" value={@q} class="input input-bordered mt-1 w-full" />
            </label>
            <fieldset class="space-y-2 text-sm">
              <legend class="font-medium">{text(@locale, :sections)}</legend>
              <label class="flex items-center gap-2">
                <input
                  type="checkbox"
                  name="show[]"
                  value="coming"
                  checked={"coming" in @show}
                  class="checkbox checkbox-sm"
                />
                {text(@locale, :coming)} ({length(@coming)})
              </label>
              <label class="flex items-center gap-2">
                <input
                  type="checkbox"
                  name="show[]"
                  value="previously"
                  checked={"previously" in @show}
                  class="checkbox checkbox-sm"
                />
                {text(@locale, :previously)} ({length(@previously)})
              </label>
            </fieldset>
            <fieldset class="space-y-2 text-sm">
              <legend class="font-medium">{text(@locale, :communes)}</legend>
              <div :for={{slug, name} <- @communes} class="flex items-center justify-between gap-2">
                <label class="flex items-center gap-2">
                  <input
                    type="checkbox"
                    name="commune[]"
                    value={slug}
                    checked={slug in @selected_communes}
                    class="checkbox checkbox-sm"
                  />
                  <span>{name}</span>
                </label>
                <button
                  type="submit"
                  form={"follow-commune-#{slug}"}
                  class="btn btn-ghost btn-xs"
                  data-follow-control
                >{text(@locale, :follow)}</button>
              </div>
            </fieldset>
            <button type="submit" class="btn btn-sm w-full">{text(@locale, :apply)}</button>
          </form>
        </aside>

        <div class="min-w-0">
          <section
            :if={"coming" in @show}
            aria-labelledby="coming-up"
            class="border-t border-base-300 pt-4"
          >
            <h2 id="coming-up" class="text-2xl font-semibold">{text(@locale, :coming)}</h2>
            <p :if={@coming == []} class="mt-3 text-base-content/70">{text(@locale, :none_coming)}</p>
            <div class="mt-3">
              <.timeline_entry :for={entry <- @coming} entry={entry} locale={@locale} />
            </div>
          </section>

          <section
            :if={"previously" in @show}
            aria-labelledby="previously"
            class="mt-8 border-t border-base-300 pt-4"
          >
            <h2 id="previously" class="text-2xl font-semibold">{text(@locale, :previously)}</h2>
            <p :if={@previously == []} class="mt-3 text-base-content/70">
              {text(@locale, :none_decided)}
            </p>
            <div class="mt-3">
              <.timeline_entry :for={entry <- @previously} entry={entry} locale={@locale} />
            </div>
          </section>
        </div>
      </div>

      <footer class="mt-12 border-t border-base-300 pt-5 text-sm text-base-content/70">
        {text(@locale, :byline)} Rico Trevisan
      </footer>
    </main>
    """
  end

  attr :entry, :map, required: true
  attr :locale, :string, required: true

  defp timeline_entry(assigns) do
    ~H"""
    <article
      class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 border-b border-base-300 py-2"
      data-commune={@entry.commune_slug}
    >
      <a href={@entry.href} class="min-w-0 flex-1 font-medium underline-offset-2 hover:underline">
        {@entry.title}
      </a>
      <p class="shrink-0 text-sm text-base-content/70">
        {@entry.commune} ·
        <time datetime={Date.to_iso8601(@entry.date)}>{format_date(@entry.date)}</time>
      </p>
    </article>
    """
  end

  attr :locale, :string, required: true
  attr :path, :string, required: true

  defp language_nav(assigns) do
    ~H"""
    <nav aria-label="Language">
      <ul class="flex gap-3 text-sm">
        <li :for={{code, label} <- [{"fr", "FR"}, {"nl", "NL"}, {"en", "EN"}]}>
          <a
            href={@path <> "?lang=" <> code}
            lang={code}
            hreflang={code}
            aria-current={if code == @locale, do: "page"}
            class="underline underline-offset-2"
          >{label}</a>
        </li>
      </ul>
    </nav>
    """
  end

  defp entry(page, item, locale) do
    variant =
      Enum.find(item.coverage_variants, &(&1.locale == locale)) ||
        unavailable_coverage_variant(locale)

    decision = loaded_or_nil(item.published_decision)
    state = display_state(item, decision)

    %{
      commune:
        commune_name(locale, page.council_meeting.commune.slug, page.council_meeting.commune.name),
      commune_slug: page.council_meeting.commune.slug,
      date: page.council_meeting.scheduled_on,
      item_number: item.published_item_number || item.item_number,
      title: variant.title,
      summary: localized_summary(variant, state, locale),
      provenance: variant.provenance,
      state: state,
      disposition: decision && decision.disposition,
      outcome: item.published_outcome || :unknown,
      evidences: BrusselsWtfWeb.PublicEvidence.for_item(item),
      dossiers: Enum.map(item.dossier_links, & &1.dossier),
      href:
        "/meetings/#{page.council_meeting.commune.slug}/#{page.council_meeting.municipal_identifier}" <>
          "?lang=#{locale}##{item.stable_anchor}",
      search_text:
        [
          variant.title,
          variant.summary,
          commune_name(
            locale,
            page.council_meeting.commune.slug,
            page.council_meeting.commune.name
          ),
          item.published_item_number || item.item_number,
          Date.to_iso8601(page.council_meeting.scheduled_on)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
    }
  end

  defp unavailable_coverage_variant(locale) do
    %{
      title: text(locale, :item_unavailable),
      summary: text(locale, :unavailable_explanation),
      proposal_summary: nil,
      decision_summary: nil,
      provenance: []
    }
  end

  defp display_state(_item, decision) when not is_nil(decision), do: :decision
  defp display_state(%{published_procedural_state: :decision}, nil), do: :unknown
  defp display_state(item, nil), do: item.published_procedural_state || :unknown

  defp localized_summary(variant, :decision, locale),
    do: variant.decision_summary || text(locale, :decision_copy_unavailable)

  defp localized_summary(variant, _state, _locale),
    do: variant.proposal_summary || variant.summary

  defp selected_sections(params) do
    selected =
      params
      |> Map.get("show")
      |> List.wrap()
      |> Enum.filter(&(&1 in ~w(coming previously)))

    if selected == [], do: ~w(coming previously), else: selected
  end

  defp selected_communes(%{"communes_submitted" => _} = params),
    do: normalize_communes(params["commune"])

  defp selected_communes(%{"commune" => values}), do: normalize_communes(values)
  defp selected_communes(_params), do: @slugs

  defp normalize_communes(values) do
    values
    |> List.wrap()
    |> Enum.filter(&(&1 in @slugs))
    |> Enum.uniq()
  end

  defp newest_first(entries), do: Enum.sort_by(entries, & &1.date, {:desc, Date})

  defp loaded_or_nil(%Ash.NotLoaded{}), do: nil
  defp loaded_or_nil(value), do: value

  defp commune_name("fr", "city-of-brussels", _name), do: "Ville de Bruxelles"
  defp commune_name("nl", "city-of-brussels", _name), do: "Stad Brussel"
  defp commune_name("nl", "ixelles", _name), do: "Elsene"
  defp commune_name("nl", "uccle", _name), do: "Ukkel"
  defp commune_name("nl", "forest", _name), do: "Vorst"
  defp commune_name(_locale, _slug, name), do: name

  defp format_date(date), do: Date.to_iso8601(date)

  defp text("fr", key), do: Map.fetch!(fr_text(), key)
  defp text("nl", key), do: Map.fetch!(nl_text(), key)
  defp text(_locale, key), do: Map.fetch!(en_text(), key)

  defp en_text do
    %{
      skip: "Skip to content",
      unavailable_title: "Coverage unavailable in English",
      item_unavailable: "Agenda-item coverage unavailable in English",
      unavailable_explanation:
        "No complete English coverage is available; no other language is substituted.",
      decision_copy_unavailable: "Decision copy is unavailable in English.",
      synthetic_reference: "Demonstration reference — not evidence of council activity",
      dossiers: "Dossiers",
      title: "Council coverage",
      intro:
        "Upcoming proposals, unresolved outcomes, and documented decisions from four Brussels communes.",
      communes: "Communes",
      follow: "Follow",
      apply: "Apply selection",
      search: "Search",
      sections: "Sections",
      coming: "Coming up",
      previously: "Previously",
      unknown_heading: "Outcome not yet documented",
      decided: "What they decided",
      none_coming: "No upcoming coverage.",
      none_decided: "No documented decisions.",
      item: "Agenda item",
      proposal: "Proposal",
      outcome_unknown: "Outcome unknown",
      decision: "Decision",
      provenance: "Content provenance",
      source: "Source",
      byline: "By"
    }
  end

  defp fr_text do
    %{
      skip: "Aller au contenu",
      unavailable_title: "Contenu indisponible en français",
      item_unavailable: "Contenu du point indisponible en français",
      unavailable_explanation:
        "Aucune version française complète n’est disponible ; aucune autre langue n’est substituée.",
      decision_copy_unavailable: "Le texte de la décision n’est pas disponible en français.",
      synthetic_reference:
        "Référence de démonstration — ne constitue pas une preuve d’activité communale",
      dossiers: "Dossiers",
      title: "Actualité des conseils communaux",
      intro:
        "Propositions à venir, résultats non documentés et décisions officielles de quatre communes bruxelloises.",
      communes: "Communes",
      follow: "Suivre",
      apply: "Appliquer la sélection",
      search: "Rechercher",
      sections: "Sections",
      coming: "À venir",
      previously: "Auparavant",
      unknown_heading: "Résultat pas encore documenté",
      decided: "Ce qu’ils ont décidé",
      none_coming: "Aucune actualité à venir.",
      none_decided: "Aucune décision documentée.",
      item: "Point",
      proposal: "Proposition",
      outcome_unknown: "Résultat inconnu",
      decision: "Décision",
      provenance: "Provenance du contenu",
      source: "Source",
      byline: "Par"
    }
  end

  defp nl_text do
    %{
      skip: "Naar inhoud",
      unavailable_title: "Inhoud niet beschikbaar in het Nederlands",
      item_unavailable: "Inhoud van het agendapunt niet beschikbaar in het Nederlands",
      unavailable_explanation:
        "Er is geen volledige Nederlandse versie beschikbaar; een andere taal wordt niet ingevoegd.",
      decision_copy_unavailable: "De beslissingstekst is niet beschikbaar in het Nederlands.",
      synthetic_reference: "Demonstratiereferentie — geen bewijs van gemeentelijke activiteit",
      dossiers: "Dossiers",
      title: "Nieuws uit de gemeenteraden",
      intro:
        "Komende voorstellen, niet-gedocumenteerde resultaten en officiële besluiten uit vier Brusselse gemeenten.",
      communes: "Gemeenten",
      follow: "Volgen",
      apply: "Selectie toepassen",
      search: "Zoeken",
      sections: "Onderdelen",
      coming: "Binnenkort",
      previously: "Eerder",
      unknown_heading: "Resultaat nog niet gedocumenteerd",
      decided: "Wat ze beslisten",
      none_coming: "Geen komende berichtgeving.",
      none_decided: "Geen gedocumenteerde besluiten.",
      item: "Agendapunt",
      proposal: "Voorstel",
      outcome_unknown: "Resultaat onbekend",
      decision: "Besluit",
      provenance: "Herkomst van de inhoud",
      source: "Bron",
      byline: "Door"
    }
  end
end
