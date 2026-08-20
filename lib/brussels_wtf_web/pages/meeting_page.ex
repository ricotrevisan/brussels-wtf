defmodule BrusselsWtfWeb.MeetingPage do
  use BrusselsWtfWeb, :dstar_page

  alias BrusselsWtf.Council

  @impl Dstar.Page
  def mount(conn, %{"commune" => commune, "municipal_id" => municipal_id} = params) do
    locale = BrusselsWtfWeb.Locale.resolve(conn, params)

    case Council.get_published_meeting_page(commune, municipal_id) do
      {:ok, page} ->
        variant = Enum.find(page.locale_variants, &(&1.locale == locale))
        locale_available = not is_nil(variant)
        withdrawn = page.publication_status == :draft and not is_nil(page.withdrawn_at)
        resource_path = "/meetings/#{commune}/#{municipal_id}"

        assign(conn,
          page_title:
            cond do
              withdrawn -> text(locale, :withdrawn_title)
              locale_available -> variant.title
              true -> text(locale, :unavailable_title)
            end,
          html_lang: locale,
          resource_path: resource_path,
          meeting_page: page,
          variant: variant,
          locale_available: locale_available,
          withdrawn: withdrawn,
          withdrawal_reason: page.withdrawal_reasons[locale],
          corrections: correction_notes(page.publication_revisions, locale),
          locale: locale,
          commune_name: commune_name(locale, commune, page.council_meeting.commune.name),
          items:
            if(locale_available and not withdrawn,
              do:
                page.council_meeting.agenda_items
                |> Enum.filter(& &1.published?)
                |> Enum.sort_by(&item_sort_key/1),
              else: []
            ),
          withdrawn_items:
            if(withdrawn,
              do:
                page.council_meeting.agenda_items
                |> Enum.filter(& &1.published?)
                |> Enum.sort_by(&item_sort_key/1),
              else: []
            )
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
      <h1 class="mt-2 text-3xl font-semibold tracking-tight">
        <%= cond do %>
          <% @withdrawn -> %>
            {text(@locale, :withdrawn_title)}
          <% @locale_available -> %>
            {@variant.title}
          <% true -> %>
            {text(@locale, :unavailable_title)}
        <% end %>
      </h1>
      <p
        :if={not @withdrawn and not @locale_available}
        class="mt-5 border-l-4 border-warning pl-3 leading-7"
      >
        {text(@locale, :unavailable_explanation)}
      </p>
      <p
        :if={not @withdrawn and @meeting_page.revision_published_at}
        class="mt-3 text-sm text-base-content/70"
      >
        {text(@locale, :revision)}
        <time datetime={DateTime.to_iso8601(@meeting_page.revision_published_at)}>
          {format_datetime(@meeting_page.revision_published_at)}
        </time>
      </p>

      <section :if={@withdrawn} class="mt-8 border-l-4 border-warning pl-4">
        <h2 class="text-xl font-semibold">{text(@locale, :withdrawn_heading)}</h2>
        <p class="mt-2 leading-7">{@withdrawal_reason || text(@locale, :withdrawn_explanation)}</p>
        <p :if={@meeting_page.withdrawn_at} class="mt-2 text-sm text-base-content/70">
          {text(@locale, :withdrawn_on)}
          <time datetime={DateTime.to_iso8601(@meeting_page.withdrawn_at)}>
            {format_datetime(@meeting_page.withdrawn_at)}
          </time>
        </p>
      </section>

      <div :if={@withdrawn} class="mt-8 divide-y divide-base-300">
        <section
          :for={item <- @withdrawn_items}
          id={item.stable_anchor}
          class="scroll-mt-4 py-5"
          tabindex="-1"
        >
          <h2 class="font-semibold">{text(@locale, :item)} {public_item_number(item)}</h2>
          <p class="mt-2 text-sm">{text(@locale, :item_withdrawn)}</p>
        </section>
      </div>

      <section :if={not @withdrawn and @corrections != []} class="mt-8 border-y border-base-300 py-4">
        <h2 class="font-semibold">{text(@locale, :corrections)}</h2>
        <ul class="mt-2 space-y-2 text-sm">
          <li :for={correction <- @corrections}>
            <time datetime={DateTime.to_iso8601(correction.published_at)}>
              {format_datetime(correction.published_at)}
            </time>
            · {correction.note}
          </li>
        </ul>
      </section>

      <div :if={not @withdrawn} class="mt-9 divide-y divide-base-300">
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
        unavailable_coverage_variant(assigns.locale)

    assigns =
      assigns
      |> assign(:coverage_variant, variant)
      |> assign(:display_state, display_state(assigns.item))
      |> assign(:proposals, BrusselsWtfWeb.PublicEvidence.proposals(assigns.item))
      |> assign(:source_proposals, BrusselsWtfWeb.PublicEvidence.source_proposals(assigns.item))
      |> assign(:evidences, BrusselsWtfWeb.PublicEvidence.for_item(assigns.item))

    ~H"""
    <article id={@item.stable_anchor} class="scroll-mt-4 py-7" tabindex="-1">
      <p class="text-sm font-medium text-base-content/70">
        {text(@locale, :item)} {public_item_number(@item)}
      </p>
      <h2 class="mt-2 text-2xl font-semibold leading-snug">{@coverage_variant.title}</h2>

      <div class="mt-4 space-y-3">
        <div :if={@proposals != []}>
          <h3 class="font-semibold">{text(@locale, :proposal)}</h3>
          <p class="mt-1 leading-7">
            {proposal_copy(@coverage_variant, @display_state, @locale)}
          </p>
          <blockquote
            :for={proposal <- @source_proposals}
            class="mt-3 border-l-2 border-base-300 pl-3 text-sm"
          >
            {proposal.text}
          </blockquote>
          <p
            :if={@source_proposals != [] and (@item.published_outcome || :unknown) == :unknown}
            class="mt-2 text-sm"
          >
            {unknown_outcome_label(@locale)}
          </p>
        </div>

        <div
          :if={@display_state in [:proposal, :unknown]}
          class="border-l-4 border-warning pl-3"
        >
          <h3 class="font-semibold">{text(@locale, :outcome_unknown)}</h3>
          <p class="mt-1 text-sm">{text(@locale, :unknown_explanation)}</p>
        </div>

        <div :if={@display_state == :decision} class="border-l-4 border-success pl-3">
          <h3 class="font-semibold">
            {text(@locale, :decision)}: {disposition_label(
              @locale,
              loaded_value(@item.published_decision, :disposition)
            )}
          </h3>
          <p class="mt-1 leading-7">
            {@coverage_variant.decision_summary || text(@locale, :decision_copy_unavailable)}
          </p>
          <p :if={vote_summary(@item.published_decision, @locale)} class="mt-2 text-sm">
            {vote_summary(@item.published_decision, @locale)}
          </p>
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
          <li :for={link <- @item.dossier_links}>
            <a
              href={"/dossiers/#{link.dossier.slug}?lang=#{@locale}"}
              class="underline underline-offset-2"
            >{link.dossier.title}</a>
          </li>
        </ul>
      </div>

      <section aria-label={text(@locale, :evidence)} class="mt-6">
        <h3 class="font-semibold">{text(@locale, :evidence)}</h3>
        <ul :if={@evidences != []} class="mt-2 space-y-3">
          <li :for={evidence <- @evidences} class="text-sm">
            <a href={evidence.citation_url} rel="external" class="underline underline-offset-2">
              {evidence.source_title}
            </a>
            <span :if={evidence.synthetic} class="block font-medium text-warning">
              {text(@locale, :synthetic_reference)}
            </span>
            <span :if={not evidence.synthetic} class="block text-base-content/70">
              {evidence.location} · {text(@locale, :retrieved)}
              <time datetime={DateTime.to_iso8601(evidence.retrieved_at)}>
                {format_datetime(evidence.retrieved_at)}
              </time>
              <%= if evidence.checksum do %>
                · SHA-256 <code class="break-all">{evidence.checksum}</code>
              <% end %>
            </span>
          </li>
        </ul>
        <p :if={@evidences == []} class="mt-2 text-sm">
          <a href={@page.citation_url} rel="external" class="underline underline-offset-2">
            {text(@locale, :source)}
          </a>
        </p>
      </section>
    </article>
    """
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

  defp correction_notes(revisions, locale) do
    revisions
    |> Enum.filter(&(&1.revision_kind == :factual_correction))
    |> Enum.map(fn revision ->
      %{published_at: revision.published_at, note: revision.correction_notes[locale]}
    end)
    |> Enum.reject(&is_nil(&1.note))
  end

  defp proposal_copy(variant, :decision, locale),
    do: variant.proposal_summary || text(locale, :proposal_copy_unavailable)

  defp proposal_copy(variant, _state, _locale),
    do: variant.proposal_summary || variant.summary

  defp display_state(item) do
    cond do
      loaded?(item.published_decision) -> :decision
      item.published_procedural_state == :decision -> :unknown
      true -> item.published_procedural_state || :unknown
    end
  end

  defp public_item_number(item), do: item.published_item_number || item.item_number

  defp item_sort_key(item) do
    item_number = public_item_number(item)

    case Integer.parse(item_number) do
      {number, ""} -> {0, number}
      _ -> {1, item_number}
    end
  end

  defp loaded?(%Ash.NotLoaded{}), do: false
  defp loaded?(nil), do: false
  defp loaded?(_value), do: true

  defp loaded_value(%Ash.NotLoaded{}, _field), do: nil
  defp loaded_value(nil, _field), do: nil
  defp loaded_value(value, field), do: Map.fetch!(value, field)

  defp vote_summary(%Ash.NotLoaded{}, _locale), do: nil
  defp vote_summary(nil, _locale), do: nil

  defp vote_summary(decision, locale) do
    values = [decision.votes_for, decision.votes_against, decision.abstentions]

    if Enum.all?(values, &is_nil/1) do
      nil
    else
      [
        vote_part(locale, :for, decision.votes_for),
        vote_part(locale, :against, decision.votes_against),
        vote_part(locale, :abstentions, decision.abstentions)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")
    end
  end

  defp vote_part(_locale, _kind, nil), do: nil
  defp vote_part("fr", :for, value), do: "#{value} pour"
  defp vote_part("fr", :against, value), do: "#{value} contre"
  defp vote_part("fr", :abstentions, value), do: "#{value} abstention(s)"
  defp vote_part("nl", :for, value), do: "#{value} voor"
  defp vote_part("nl", :against, value), do: "#{value} tegen"
  defp vote_part("nl", :abstentions, value), do: "#{value} onthouding(en)"
  defp vote_part(_locale, :for, value), do: "#{value} for"
  defp vote_part(_locale, :against, value), do: "#{value} against"
  defp vote_part(_locale, :abstentions, value), do: "#{value} abstention(s)"

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

  defp unknown_outcome_label("fr"), do: "Résultat inconnu"
  defp unknown_outcome_label("nl"), do: "Onbekende uitkomst"
  defp unknown_outcome_label(_locale), do: "Unknown outcome"

  defp text("fr", key), do: Map.fetch!(fr_text(), key)
  defp text("nl", key), do: Map.fetch!(nl_text(), key)
  defp text(_locale, key), do: Map.fetch!(en_text(), key)

  defp en_text do
    %{
      skip: "Skip to content",
      unavailable_title: "Coverage unavailable in English",
      item_unavailable: "Agenda-item coverage unavailable in English",
      unavailable_explanation:
        "This meeting has no complete English coverage. No text from another language is substituted.",
      decision_copy_unavailable: "Decision copy is unavailable in English.",
      proposal_copy_unavailable: "Proposal copy is unavailable in English.",
      synthetic_reference: "Demonstration reference — not evidence of council activity",
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
      byline: "By",
      withdrawn_title: "Meeting coverage withdrawn",
      withdrawn_heading: "This coverage has been withdrawn",
      withdrawn_explanation: "The page is temporarily unavailable while its content is reviewed.",
      withdrawn_on: "Withdrawn:",
      item_withdrawn: "Coverage for this agenda item is temporarily unavailable.",
      corrections: "Corrections"
    }
  end

  defp fr_text do
    %{
      skip: "Aller au contenu",
      unavailable_title: "Contenu indisponible en français",
      item_unavailable: "Contenu du point indisponible en français",
      unavailable_explanation:
        "Cette réunion ne dispose pas d’une version française complète. Aucun texte d’une autre langue n’est substitué.",
      decision_copy_unavailable: "Le texte de la décision n’est pas disponible en français.",
      proposal_copy_unavailable: "Le texte de la proposition n’est pas disponible en français.",
      synthetic_reference:
        "Référence de démonstration — ne constitue pas une preuve d’activité communale",
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
      byline: "Par",
      withdrawn_title: "Contenu de la réunion retiré",
      withdrawn_heading: "Ce contenu a été retiré",
      withdrawn_explanation:
        "La page est temporairement indisponible pendant la vérification de son contenu.",
      withdrawn_on: "Retiré le :",
      item_withdrawn: "Le contenu de ce point est temporairement indisponible.",
      corrections: "Corrections"
    }
  end

  defp nl_text do
    %{
      skip: "Naar inhoud",
      unavailable_title: "Inhoud niet beschikbaar in het Nederlands",
      item_unavailable: "Inhoud van het agendapunt niet beschikbaar in het Nederlands",
      unavailable_explanation:
        "Voor deze vergadering is geen volledige Nederlandse versie beschikbaar. Tekst uit een andere taal wordt niet ingevoegd.",
      decision_copy_unavailable: "De beslissingstekst is niet beschikbaar in het Nederlands.",
      proposal_copy_unavailable: "De voorsteltekst is niet beschikbaar in het Nederlands.",
      synthetic_reference: "Demonstratiereferentie — geen bewijs van gemeentelijke activiteit",
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
      byline: "Door",
      withdrawn_title: "Vergaderbericht ingetrokken",
      withdrawn_heading: "Dit bericht is ingetrokken",
      withdrawn_explanation:
        "De pagina is tijdelijk niet beschikbaar terwijl de inhoud wordt nagekeken.",
      withdrawn_on: "Ingetrokken op:",
      item_withdrawn: "Het bericht over dit agendapunt is tijdelijk niet beschikbaar.",
      corrections: "Correcties"
    }
  end
end
