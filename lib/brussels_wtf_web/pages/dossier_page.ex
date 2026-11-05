defmodule BrusselsWtfWeb.DossierPage do
  use BrusselsWtfWeb, :dstar_page

  alias BrusselsWtf.Council

  @impl Dstar.Page
  def mount(conn, %{"slug" => slug} = params) do
    locale = BrusselsWtfWeb.Locale.resolve(conn, params)

    case Council.get_dossier(slug) do
      {:ok, %{status: :retired, retired_into: retired_into}}
      when not is_nil(retired_into) and not is_struct(retired_into, Ash.NotLoaded) ->
        conn
        |> Plug.Conn.put_status(308)
        |> Phoenix.Controller.redirect(to: "/dossiers/#{retired_into.slug}?lang=#{locale}")

      {:ok, dossier} ->
        entries = entries(dossier, locale)

        assign(BrusselsWtfWeb.FollowControl.load(conn),
          page_title: text(locale, :title) <> ": " <> dossier_title(dossier, locale),
          html_lang: locale,
          resource_path: BrusselsWtfWeb.PublicUrl.dossier_path(slug),
          noindex: entries == [],
          meta_description:
            BrusselsWtfWeb.PublicDescription.dossier(locale, dossier_title(dossier, locale)),
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
    <BrusselsWtfWeb.PublicShell.header
      locale={@locale}
      reader_back={true}
      lang_href={fn code -> "/dossiers/#{@dossier.slug}?lang=" <> code end}
    />

    <main id="content" class="site-container py-6 sm:py-8" tabindex="-1">
      <p class="eyebrow">{text(@locale, :dossier)}</p>
      <h1 class="display display-lg mt-1">
        {text(@locale, :title)}: {dossier_title(@dossier, @locale)}
      </h1>
      <BrusselsWtfWeb.FollowControl.control
        follow={BrusselsWtfWeb.FollowControl.find(@citizen_follows, "dossier", @dossier.slug)}
        locale={@locale}
        type="dossier"
        identifier={@dossier.slug}
        label={text(@locale, :follow)}
      />

      <p :if={@entries == []} class="callout measure mt-6" data-dossier-empty>
        {text(@locale, :empty)}
      </p>
      <ol :if={@entries != []} class="dossier-rail mt-8 border-l-2 border-base-300 pl-6">
        <li :for={entry <- @entries} class="relative pb-8">
          <span
            aria-hidden="true"
            class={[
              "timeline-dot",
              (entry.disposition && "timeline-dot-decided") || "timeline-dot-unknown"
            ]}
          ></span>
          <p class="eyebrow">
            {entry.commune} ·
            <time datetime={Date.to_iso8601(entry.date)}>
              {BrusselsWtfWeb.PublicDate.long(entry.date, @locale)}
            </time>
            · {text(@locale, :item)} {entry.item_number}
          </p>
          <h2 class="mt-1 text-lg font-semibold leading-snug">
            <a href={entry.href} class={["entry-title", entry.headline && "has-headline"]}>
              <BrusselsWtfWeb.PublicShell.title_parts
                title={entry.title}
                headline={entry.headline}
                locale={@locale}
              />
            </a>
          </h2>
          <p class="mt-1.5">
            <BrusselsWtfWeb.PublicShell.status
              kind={entry.disposition || :unknown}
              label={state_label(@locale, entry.disposition)}
            />
          </p>
          <p class="measure mt-2 leading-6">{entry.summary}</p>
          <p :for={evidence <- entry.evidences} class="mt-1 text-sm">
            <a
              href={BrusselsWtfWeb.PublicEvidence.citation_href(evidence)}
              rel="external"
              class="inline-flex min-h-11 items-center gap-1.5"
            >
              <span class="hero-document-text-micro size-4 shrink-0" aria-hidden="true"></span>
              {if evidence.source_title == "Authoritative municipal source",
                do: evidence.location || source_title(@locale),
                else: evidence.source_title}
            </a>
            <span :if={evidence.synthetic} class="tone-unknown block font-medium">
              {text(@locale, :synthetic_reference)}
            </span>
          </p>
          <details class="disclosure text-sm">
            <summary>
              <span class="hero-flag-micro size-4" aria-hidden="true"></span>{text(
                @locale,
                :report_link
              )}
            </summary>
            <form
              method="post"
              action={"/dossiers/#{@dossier.slug}/links/#{entry.link_id}/reports"}
              class="mt-3 border border-base-300 p-3"
            >
              <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
              <label>
                {text(@locale, :report_reason)}
                <textarea
                  name="reason"
                  required
                  minlength="10"
                  class="textarea textarea-bordered mt-1 w-full"
                ></textarea>
              </label>
              <button type="submit" class="btn btn-sm mt-2 min-h-11">{text(@locale, :submit_report)}</button>
            </form>
          </details>
        </li>
      </ol>
    </main>
    <BrusselsWtfWeb.PublicationComponents.footer locale={@locale} />
    """
  end

  @doc "Whether the dossier has publicly rendered entries in every language."
  def indexable?(%{status: :active} = dossier) do
    Enum.all?(BrusselsWtfWeb.PublicUrl.locales(), &(entries(dossier, &1) != []))
  end

  def indexable?(_dossier), do: false

  defp entries(dossier, locale) do
    dossier.dossier_links
    |> Enum.flat_map(&entry(&1, locale))
    |> Enum.sort_by(& &1.date, {:asc, Date})
  end

  defp dossier_disposition(item) do
    case loaded_or_nil(Map.get(item, :published_decision)) do
      nil -> nil
      decision -> decision.disposition
    end
  end

  defp state_label("fr", nil), do: "Résultat inconnu"
  defp state_label("nl", nil), do: "Uitkomst onbekend"
  defp state_label(_locale, nil), do: "Outcome unknown"

  defp state_label(locale, disposition),
    do: String.capitalize(BrusselsWtfWeb.DispositionLabels.label(locale, disposition))

  defp dossier_title(dossier, locale),
    do: dossier.localized_titles[locale] || dossier.title

  @doc false
  def published_variant(page, item, locale) do
    revision = loaded_or_nil(page.current_revision)
    item_key = item.authoritative_identifier || item.continuity_key

    if revision do
      get_in(revision.content, ["items", item_key, "variants", locale])
    else
      proposals = loaded_list(Map.get(item, :proposals))

      if Application.get_env(:brussels_wtf, :allow_synthetic_seeds, false) and proposals != [] and
           Enum.all?(proposals, & &1.synthetic) do
        synthetic_variant(item, locale)
      end
    end
  end

  defp synthetic_variant(item, locale) do
    case Enum.find(item.coverage_variants, &(&1.locale == locale)) do
      nil ->
        nil

      variant ->
        %{
          "title" => variant.title,
          "headline" => variant.headline,
          "summary" => variant.summary,
          "proposal_summary" => variant.proposal_summary,
          "decision_summary" => variant.decision_summary
        }
    end
  end

  defp source_title("fr"), do: "Source communale officielle"
  defp source_title("nl"), do: "Officiële gemeentelijke bron"
  defp source_title(_locale), do: "Official municipal source"

  defp entry(%{status: :removed}, _locale), do: []

  defp entry(link, locale) do
    item = link.agenda_item
    meeting = item.council_meeting
    page = loaded_or_nil(meeting.meeting_page)

    variant = page && published_variant(page, item, locale)

    if page && page.publication_status == :published && variant do
      state = item.published_procedural_state || :unknown

      [
        %{
          link_id: link.id,
          disposition: dossier_disposition(item),
          commune: commune_name(locale, meeting.commune.slug, meeting.commune.name),
          date: meeting.scheduled_on,
          item_number: item.published_item_number || item.item_number,
          title: variant["title"],
          headline: variant["headline"],
          summary: summary(variant, state, locale),
          evidences: BrusselsWtfWeb.PublicEvidence.for_item(item),
          href:
            "/meetings/#{meeting.commune.slug}/#{meeting.municipal_identifier}?lang=#{locale}##{item.stable_anchor}"
        }
      ]
    else
      []
    end
  end

  defp summary(variant, :decision, locale),
    do: variant["decision_summary"] || text(locale, :decision_unavailable)

  defp summary(variant, _state, _locale),
    do: variant["proposal_summary"] || variant["summary"]

  defp loaded_list(%Ash.NotLoaded{}), do: []
  defp loaded_list(nil), do: []
  defp loaded_list(values), do: values

  defp loaded_or_nil(%Ash.NotLoaded{}), do: nil
  defp loaded_or_nil(value), do: value

  defp commune_name("fr", "city-of-brussels", _name), do: "Ville de Bruxelles"
  defp commune_name("nl", "city-of-brussels", _name), do: "Stad Brussel"
  defp commune_name("nl", "ixelles", _name), do: "Elsene"
  defp commune_name("nl", "uccle", _name), do: "Ukkel"
  defp commune_name("nl", "forest", _name), do: "Vorst"
  defp commune_name(_locale, _slug, name), do: name

  defp text("fr", :empty), do: "Aucun point publié n’est encore lié à ce dossier."
  defp text("fr", :dossier), do: "Dossier en cours"
  defp text("fr", :title), do: "Chronologie du dossier"
  defp text("fr", :item), do: "Point"
  defp text("fr", :follow), do: "Suivre ce dossier"

  defp text("fr", :decision_unavailable),
    do: "Le texte de la décision n’est pas disponible en français."

  defp text("fr", :synthetic_reference),
    do: "Référence de démonstration — ne constitue pas une preuve d’activité communale"

  defp text("fr", :report_link), do: "Signaler un lien de dossier incorrect"
  defp text("fr", :report_reason), do: "Pourquoi ce lien est-il incorrect ?"
  defp text("fr", :submit_report), do: "Envoyer le signalement"
  defp text("nl", :empty), do: "Er is nog geen gepubliceerd agendapunt aan dit dossier gekoppeld."
  defp text("nl", :dossier), do: "Lopend dossier"
  defp text("nl", :title), do: "Dossiertijdlijn"
  defp text("nl", :item), do: "Agendapunt"
  defp text("nl", :follow), do: "Dit dossier volgen"

  defp text("nl", :decision_unavailable),
    do: "De beslissingstekst is niet beschikbaar in het Nederlands."

  defp text("nl", :synthetic_reference),
    do: "Demonstratiereferentie — geen bewijs van gemeentelijke activiteit"

  defp text("nl", :report_link), do: "Een onjuiste dossierlink melden"
  defp text("nl", :report_reason), do: "Waarom is deze link onjuist?"
  defp text("nl", :submit_report), do: "Melding versturen"
  defp text(_locale, :empty), do: "No published agenda item is linked to this dossier yet."
  defp text(_locale, :dossier), do: "Continuing dossier"
  defp text(_locale, :title), do: "Dossier timeline"
  defp text(_locale, :item), do: "Agenda item"
  defp text(_locale, :follow), do: "Follow this dossier"
  defp text(_locale, :decision_unavailable), do: "Decision copy is unavailable in English."

  defp text(_locale, :synthetic_reference),
    do: "Demonstration reference — not evidence of council activity"

  defp text(_locale, :report_link), do: "Report an incorrect dossier link"
  defp text(_locale, :report_reason), do: "Why is this link incorrect?"
  defp text(_locale, :submit_report), do: "Submit report"
end
