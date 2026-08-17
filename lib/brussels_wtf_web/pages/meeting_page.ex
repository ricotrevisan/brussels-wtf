defmodule BrusselsWtfWeb.MeetingPage do
  use BrusselsWtfWeb, :dstar_page

  alias BrusselsWtf.Council

  @impl Dstar.Page
  def mount(conn, %{"commune" => commune, "municipal_id" => municipal_id} = params) do
    locale = BrusselsWtfWeb.Locale.resolve(conn, params)

    case Council.get_published_meeting_page(commune, municipal_id) do
      {:ok, page} ->
        variant = locale_variant(page.locale_variants, locale)
        resource_path = "/meetings/#{commune}/#{municipal_id}"

        assign(conn,
          page_title: variant.title,
          html_lang: locale,
          resource_path: resource_path,
          meeting_page: page,
          variant: variant,
          locale: locale,
          commune_name: commune_name(locale, commune, page.council_meeting.commune.name),
          items: Enum.sort_by(page.council_meeting.agenda_items, &item_sort_key/1)
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
                href={@resource_path <> "?lang=" <> code}
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

    <main id="content" class="mx-auto max-w-4xl px-4 py-8 text-base-content" tabindex="-1">
      <p class="text-sm text-base-content/70">
        {@commune_name} ·
        <time datetime={Date.to_iso8601(@meeting_page.council_meeting.scheduled_on)}>
          {format_date(@meeting_page.council_meeting.scheduled_on)}
        </time>
      </p>
      <h1 class="mt-2 text-3xl font-semibold tracking-tight">{@variant.title}</h1>
      <p :if={@meeting_page.revision_published_at} class="mt-3 text-sm text-base-content/70">
        {text(@locale, :revision)}
        <time datetime={DateTime.to_iso8601(@meeting_page.revision_published_at)}>
          {format_datetime(@meeting_page.revision_published_at)}
        </time>
      </p>

      <div class="mt-9 divide-y divide-base-300">
        <.coverage_item :for={item <- @items} item={item} page={@meeting_page} locale={@locale} />
      </div>

      <footer class="mt-12 border-t border-base-300 pt-5 text-sm text-base-content/70">
        {text(@locale, :byline)} Rico Trevisan
      </footer>
    </main>
    """
  end

  attr :item, :any, required: true
  attr :page, :any, required: true
  attr :locale, :string, required: true

  defp coverage_item(assigns) do
    variant =
      Enum.find(assigns.item.coverage_variants, &(&1.locale == assigns.locale)) ||
        locale_variant(assigns.page.locale_variants, assigns.locale)

    assigns = assign(assigns, :coverage_variant, variant)

    ~H"""
    <article id={@item.stable_anchor} class="scroll-mt-4 py-7" tabindex="-1">
      <p class="text-sm font-medium text-base-content/70">
        {text(@locale, :item)} {@item.item_number}
      </p>
      <h2 class="mt-2 text-2xl font-semibold leading-snug">{@coverage_variant.title}</h2>

      <div class="mt-4 space-y-3">
        <div :if={loaded?(@item.proposal)}>
          <h3 class="font-semibold">{text(@locale, :proposal)}</h3>
          <p class="mt-1 leading-7">{@coverage_variant.summary}</p>
        </div>

        <div
          :if={@item.procedural_state in [:proposal, :unknown]}
          class="border-l-4 border-warning pl-3"
        >
          <h3 class="font-semibold">{text(@locale, :outcome_unknown)}</h3>
          <p class="mt-1 text-sm">{text(@locale, :unknown_explanation)}</p>
        </div>

        <div :if={loaded?(@item.decision)} class="border-l-4 border-success pl-3">
          <h3 class="font-semibold">
            {text(@locale, :decision)}: {disposition_label(
              @locale,
              loaded_value(@item.decision, :disposition)
            )}
          </h3>
          <p class="mt-1 leading-7">{@coverage_variant.summary}</p>
        </div>
      </div>

      <div class="mt-4 flex flex-wrap gap-2" aria-label={text(@locale, :provenance)}>
        <span
          :for={label <- provenance_labels(@coverage_variant.provenance)}
          class="badge badge-outline"
        >
          {label}
        </span>
      </div>

      <div :if={@item.dossier_links != []} class="mt-5 text-sm">
        <p class="font-medium">{text(@locale, :dossiers)}</p>
        <ul class="mt-1 list-disc pl-5">
          <li :for={link <- @item.dossier_links}>{link.dossier.title}</li>
        </ul>
      </div>

      <section aria-label={text(@locale, :evidence)} class="mt-6">
        <h3 class="font-semibold">{text(@locale, :evidence)}</h3>
        <ul :if={@item.evidences != []} class="mt-2 space-y-3">
          <li :for={evidence <- @item.evidences} class="text-sm">
            <a href={evidence.citation_url} rel="external" class="underline underline-offset-2">
              {evidence.source_title}
            </a>
            <span class="block text-base-content/70">{evidence.location}</span>
            <span class="block text-base-content/70">
              {text(@locale, :retrieved)}
              <time datetime={DateTime.to_iso8601(evidence.retrieved_at)}>
                {format_datetime(evidence.retrieved_at)}
              </time>
              · SHA-256 <code class="break-all">{evidence.checksum}</code>
            </span>
          </li>
        </ul>
        <p :if={@item.evidences == []} class="mt-2 text-sm">
          <a href={@page.citation_url} rel="external" class="underline underline-offset-2">
            {text(@locale, :source)}
          </a>
        </p>
      </section>
    </article>
    """
  end

  defp locale_variant(variants, locale) do
    Enum.find(variants, &(&1.locale == locale)) || List.first(variants)
  end

  defp item_sort_key(item) do
    case Integer.parse(item.item_number) do
      {number, ""} -> {0, number}
      _ -> {1, item.item_number}
    end
  end

  defp loaded?(%Ash.NotLoaded{}), do: false
  defp loaded?(nil), do: false
  defp loaded?(_value), do: true

  defp loaded_value(%Ash.NotLoaded{}, _field), do: nil
  defp loaded_value(nil, _field), do: nil
  defp loaded_value(value, field), do: Map.fetch!(value, field)

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
  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp text("fr", key), do: Map.fetch!(fr_text(), key)
  defp text("nl", key), do: Map.fetch!(nl_text(), key)
  defp text(_locale, key), do: Map.fetch!(en_text(), key)

  defp en_text do
    %{
      skip: "Skip to content",
      revision: "Page revision:",
      item: "Agenda item",
      proposal: "Proposal",
      outcome_unknown: "Outcome unknown",
      unknown_explanation: "No authoritative final record is attached to this item.",
      decision: "Decision",
      provenance: "Content provenance",
      dossiers: "Continuing dossier",
      evidence: "Evidence and citations",
      source: "Authoritative source",
      retrieved: "Retrieved",
      byline: "By"
    }
  end

  defp fr_text do
    %{
      skip: "Aller au contenu",
      revision: "Révision de la page :",
      item: "Point",
      proposal: "Proposition",
      outcome_unknown: "Résultat inconnu",
      unknown_explanation: "Aucun document final officiel n’est joint à ce point.",
      decision: "Décision",
      provenance: "Provenance du contenu",
      dossiers: "Dossier en cours",
      evidence: "Preuves et citations",
      source: "Source officielle",
      retrieved: "Récupérée",
      byline: "Par"
    }
  end

  defp nl_text do
    %{
      skip: "Naar inhoud",
      revision: "Paginarevisie:",
      item: "Agendapunt",
      proposal: "Voorstel",
      outcome_unknown: "Resultaat onbekend",
      unknown_explanation: "Aan dit punt is geen officieel eindverslag gekoppeld.",
      decision: "Besluit",
      provenance: "Herkomst van de inhoud",
      dossiers: "Lopend dossier",
      evidence: "Bewijs en citaten",
      source: "Officiële bron",
      retrieved: "Opgehaald",
      byline: "Door"
    }
  end
end
