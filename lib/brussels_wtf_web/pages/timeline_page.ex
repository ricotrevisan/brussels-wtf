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

  @impl Dstar.Page
  def mount(conn, params) do
    locale = BrusselsWtfWeb.Locale.resolve(conn, params)
    selected = selected_communes(params)

    pages =
      Council.list_published_meeting_pages!()
      |> Enum.filter(&(&1.council_meeting.commune.slug in selected))

    entries =
      pages
      |> Enum.flat_map(fn page ->
        page.council_meeting.agenda_items
        |> Enum.filter(& &1.published?)
        |> Enum.map(&entry(page, &1, locale))
      end)

    assign(conn,
      page_title: "brussels.wtf",
      html_lang: locale,
      resource_path: "/",
      locale: locale,
      communes:
        Enum.map(@communes, fn {slug, name} -> {slug, commune_name(locale, slug, name)} end),
      selected_communes: selected,
      coming: entries |> Enum.filter(&(&1.state == :proposal)) |> newest_first(),
      unknown: entries |> Enum.filter(&(&1.state == :unknown)) |> newest_first(),
      decided: entries |> Enum.filter(&(&1.state == :decision)) |> newest_first()
    )
  end

  @impl Dstar.Page
  def render(assigns) do
    ~H"""
    <a href="#content" class="sr-only focus:not-sr-only focus:absolute focus:p-3 focus:bg-base-100">
      {text(@locale, :skip)}
    </a>
    <header class="border-b border-base-300">
      <div class="mx-auto flex max-w-5xl items-center justify-between gap-4 px-4 py-4">
        <a href={~p"/"} class="font-semibold tracking-wide">brussels.wtf</a>
        <.language_nav locale={@locale} path="/" />
      </div>
    </header>

    <main id="content" class="mx-auto max-w-5xl px-4 py-8 text-base-content" tabindex="-1">
      <h1 class="text-3xl font-semibold tracking-tight">{text(@locale, :title)}</h1>
      <p class="mt-2 max-w-2xl text-base-content/70">{text(@locale, :intro)}</p>

      <form method="get" action="/" data-reader-communes class="mt-7 border-y border-base-300 py-4">
        <input type="hidden" name="lang" value={@locale} />
        <input type="hidden" name="communes_submitted" value="1" />
        <fieldset>
          <legend class="font-medium">{text(@locale, :communes)}</legend>
          <div class="mt-3 flex flex-wrap gap-x-5 gap-y-2">
            <label :for={{slug, name} <- @communes} class="flex items-center gap-2">
              <input
                type="checkbox"
                name="commune[]"
                value={slug}
                checked={slug in @selected_communes}
                class="checkbox checkbox-sm"
              />
              <span>{name}</span>
            </label>
          </div>
        </fieldset>
        <button type="submit" class="btn btn-sm mt-4">{text(@locale, :apply)}</button>
      </form>

      <section aria-labelledby="coming-up" class="mt-10">
        <h2 id="coming-up" class="text-2xl font-semibold">{text(@locale, :coming)}</h2>
        <p :if={@coming == []} class="mt-3 text-base-content/70">{text(@locale, :none_coming)}</p>
        <div class="mt-4 divide-y divide-base-300">
          <.timeline_entry :for={entry <- @coming} entry={entry} locale={@locale} />
        </div>
      </section>

      <section :if={@unknown != []} aria-labelledby="outcome-unknown" class="mt-10">
        <h2 id="outcome-unknown" class="text-2xl font-semibold">{text(@locale, :unknown_heading)}</h2>
        <div class="mt-4 divide-y divide-base-300">
          <.timeline_entry :for={entry <- @unknown} entry={entry} locale={@locale} />
        </div>
      </section>

      <section aria-labelledby="decided" class="mt-10">
        <h2 id="decided" class="text-2xl font-semibold">{text(@locale, :decided)}</h2>
        <p :if={@decided == []} class="mt-3 text-base-content/70">{text(@locale, :none_decided)}</p>
        <div class="mt-4 divide-y divide-base-300">
          <.timeline_entry :for={entry <- @decided} entry={entry} locale={@locale} />
        </div>
      </section>

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
    <article class="py-5" data-commune={@entry.commune_slug}>
      <p class="text-sm text-base-content/70">
        <span class="font-medium text-base-content">{@entry.commune}</span>
        · <time datetime={Date.to_iso8601(@entry.date)}>{format_date(@entry.date)}</time>
        · {text(@locale, :item)} {@entry.item_number}
      </p>
      <h3 class="mt-2 text-xl font-semibold leading-snug">
        <a
          href={@entry.href}
          class="underline decoration-base-300 underline-offset-4 hover:decoration-current"
        >
          {@entry.title}
        </a>
      </h3>
      <p class="mt-2 font-medium">{status_label(@locale, @entry)}</p>
      <p class="mt-2 max-w-3xl leading-7">{@entry.summary}</p>
      <div class="mt-3 flex flex-wrap gap-2" aria-label={text(@locale, :provenance)}>
        <span :for={label <- provenance_labels(@entry.provenance)} class="badge badge-outline">{label}</span>
      </div>
      <p :if={@entry.dossiers != []} class="mt-3 text-sm">
        {text(@locale, :dossiers)}:
        <a
          :for={dossier <- @entry.dossiers}
          href={"/dossiers/#{dossier.slug}?lang=#{@locale}"}
          class="mr-3 underline underline-offset-2"
        >{dossier.title}</a>
      </p>
      <p :for={evidence <- @entry.evidences} class="mt-3 text-sm">
        {text(@locale, :source)}:
        <a href={evidence.citation_url} rel="external" class="underline underline-offset-2">
          {evidence.source_title}
        </a>
        <span :if={evidence.synthetic} class="block font-medium text-warning">
          {text(@locale, :synthetic_reference)}
        </span>
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
          "?lang=#{locale}##{item.stable_anchor}"
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

  defp status_label(locale, %{state: :decision, disposition: disposition}),
    do: text(locale, :decision) <> ": " <> disposition_label(locale, disposition)

  defp status_label(locale, %{state: :unknown}), do: text(locale, :outcome_unknown)

  defp status_label(locale, %{state: :proposal, outcome: :unknown}),
    do: text(locale, :proposal) <> " · " <> text(locale, :outcome_unknown)

  defp status_label(locale, _entry), do: text(locale, :proposal)

  defp disposition_label("fr", :approved), do: "approuvée"
  defp disposition_label("fr", :postponed), do: "reportée"
  defp disposition_label("fr", :rejected), do: "rejetée"
  defp disposition_label("fr", :amended), do: "amendée"
  defp disposition_label("fr", :withdrawn), do: "retirée"
  defp disposition_label("fr", :other), do: "autre"
  defp disposition_label("nl", :approved), do: "goedgekeurd"
  defp disposition_label("nl", :postponed), do: "uitgesteld"
  defp disposition_label("nl", :rejected), do: "verworpen"
  defp disposition_label("nl", :amended), do: "gewijzigd"
  defp disposition_label("nl", :withdrawn), do: "ingetrokken"
  defp disposition_label("nl", :other), do: "andere"
  defp disposition_label(_locale, value), do: value |> to_string() |> String.replace("_", " ")

  defp provenance_labels(values) do
    Enum.map(values, fn
      :ai_generated -> "AI-generated"
      :machine_translated -> "machine-translated"
      :human_reviewed -> "human-reviewed"
    end)
  end

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
      apply: "Apply selection",
      coming: "Coming up",
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
      apply: "Appliquer la sélection",
      coming: "À venir",
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
      apply: "Selectie toepassen",
      coming: "Binnenkort",
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
