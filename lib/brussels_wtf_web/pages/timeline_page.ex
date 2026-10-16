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

    path = "/" <> String.trim(conn.request_path, "/")
    homepage? = path == "/"
    directory? = path == "/mandates"
    contested? = path == "/coverage/contested-votes"
    category = Enum.find(categories(), &(&1.path == path))

    q = if homepage? or contested?, do: "", else: search_query(params["q"])

    matching =
      if directory? or contested? do
        %{}
      else
        Council.list_public_timeline!(
          communes: selected,
          locale: locale,
          commune_names:
            Map.new(@communes, fn {slug, name} -> {slug, commune_name(locale, slug, name)} end),
          search: q,
          groups: if(homepage?, do: [:coming, :awaiting, :decided], else: [category.group]),
          limit: if(homepage?, do: 5)
        )
      end

    page = if directory? or contested?, do: page_number(params["page"]), else: 1

    mandates =
      if directory? do
        BrusselsWtf.Identity.list_public_mandates!(selected, q, page)
      else
        %{mandates: [], more?: false}
      end

    contested =
      if contested? do
        Council.list_contested_decisions!(selected, page)
      else
        %{items: [], more?: false}
      end

    assign(BrusselsWtfWeb.FollowControl.load(conn),
      page_title: text(locale, title_key(directory?, contested?, category)),
      html_lang: locale,
      resource_path: path,
      homepage?: homepage?,
      directory?: directory?,
      contested?: contested?,
      title: text(locale, title_key(directory?, contested?, category)),
      home_path: selection_path("/", locale, selected),
      directory_path: selection_path("/mandates", locale, selected),
      contested_path: selection_path("/coverage/contested-votes", locale, selected),
      reset_path: selection_path(path, locale, selected),
      locale: locale,
      communes:
        Enum.map(@communes, fn {slug, name} -> {slug, commune_name(locale, slug, name)} end),
      selected_communes: selected,
      mandates: mandates.mandates,
      more_mandates?: mandates.more?,
      contested_rows: Enum.map(contested.items, &contested_row(&1, locale, selected)),
      more_contested?: contested.more?,
      page: page,
      q: q,
      language_path: selection_path(path, nil, selected, q),
      categories:
        categories()
        |> Enum.filter(&(homepage? or &1 == category))
        |> Enum.map(fn category ->
          entries = Map.fetch!(matching, category.group) |> Enum.map(&entry(&1, locale, selected))

          Map.merge(category, %{
            entries: entries,
            href: selection_path(category.path, locale, selected)
          })
        end)
    )
  end

  defp title_key(true, _contested?, _category), do: :verified_mandates
  defp title_key(_directory?, true, _category), do: :contested_votes
  defp title_key(_directory?, _contested?, category), do: (category && category.label) || :title

  defp contested_row(item, locale, selected) do
    meeting = item.council_meeting
    decision = item.published_decision
    variant = Enum.find(item.coverage_variants, &(&1.locale == locale))

    %{
      commune: commune_name(locale, meeting.commune.slug, meeting.commune.name),
      commune_slug: meeting.commune.slug,
      date: meeting.scheduled_on,
      title: if(variant, do: variant.title, else: text(locale, :item_unavailable)),
      disposition: decision.disposition,
      for: decision.votes_for,
      against: decision.votes_against,
      abstentions: decision.abstentions,
      href:
        selection_path(
          "/meetings/#{meeting.commune.slug}/#{meeting.municipal_identifier}",
          locale,
          selected
        ) <> "##{item.stable_anchor}"
    }
  end

  defp search_query(value) when is_binary(value), do: String.slice(value, 0, 200)
  defp search_query(_value), do: ""

  @impl Dstar.Page
  def render(assigns) do
    ~H"""
    <a href="#content" class="sr-only focus:not-sr-only focus:absolute focus:p-3 focus:bg-base-100">
      {text(@locale, :skip)}
    </a>
    <header class="border-b border-base-300">
      <div class="mx-auto flex max-w-6xl items-center justify-between gap-4 px-4 py-4">
        <Layouts.brand_link href={@home_path} />
        <.language_nav locale={@locale} path={@language_path} />
      </div>
    </header>

    <main
      id="content"
      class="reader-coverage mx-auto max-w-4xl px-4 py-6 sm:py-8 text-base-content"
      tabindex="-1"
    >
      <a :if={not @homepage?} href={@home_path} class="mb-5 inline-block underline underline-offset-2">{text(
        @locale,
        :back
      )}</a>
      <h1 id="coverage-title" class="text-2xl sm:text-3xl font-semibold tracking-tight">{@title}</h1>
      <p :if={@homepage?} class="mt-2 max-w-prose text-sm text-base-content/80">
        {text(@locale, :intro)}
      </p>
      <div class="mt-5">
        <form
          :for={{slug, _name} <- if(@homepage?, do: [], else: @communes)}
          id={"follow-commune-#{slug}"}
          method="post"
          action={BrusselsWtfWeb.FollowControl.action(BrusselsWtfWeb.FollowControl.find(@citizen_follows, "commune", slug)) <> "?lang=" <> @locale}
        >
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <input type="hidden" name="target_type" value="commune" />
          <input type="hidden" name="target_identifier" value={slug} />
        </form>
        <p :if={not @homepage? and map_size(@citizen_follows) > 0} class="mt-2 text-sm">
          {BrusselsWtfWeb.FollowControl.text(@locale, :history)}
        </p>
        <form method="get" action={@resource_path} data-reader-communes class="space-y-4">
          <input type="hidden" name="lang" value={@locale} />
          <input type="hidden" name="communes_submitted" value="1" />
          <label :if={not @homepage? and not @contested?} class="block text-sm font-medium">
            {text(@locale, :search)}
            <input type="search" name="q" value={@q} class="input input-bordered mt-1 w-full" />
          </label>
          <fieldset class="text-sm">
            <legend class="mb-2 font-semibold">{text(@locale, :communes)}</legend>
            <div class="grid grid-cols-2 gap-x-4 gap-y-1 sm:grid-cols-4">
              <div :for={{slug, name} <- @communes} class="min-w-0">
                <label class="flex min-h-11 items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    name="commune[]"
                    value={slug}
                    checked={slug in @selected_communes}
                    class="checkbox checkbox-sm shrink-0"
                  />
                  <span>{name}</span>
                </label>
              </div>
            </div>
          </fieldset>
          <div class="flex flex-wrap items-center gap-4">
            <button type="submit" class="btn btn-primary min-h-11">{text(@locale, :apply)}</button>
            <a
              :if={not @homepage?}
              data-reader-reset
              href={@reset_path}
              class="inline-flex min-h-11 items-center underline underline-offset-2"
            >{text(@locale, :reset)}</a>
          </div>
        </form>
        <details :if={not @homepage?} class="reader-filters mt-4">
          <summary class="cursor-pointer py-2 text-sm underline underline-offset-2">
            {text(@locale, :follow_communes)}
          </summary>
          <div class="mt-2 grid gap-3 sm:grid-cols-2">
            <div :for={{slug, name} <- @communes} class="flex items-center justify-between gap-2">
              <span>{name}</span>
              <button
                type="submit"
                form={"follow-commune-#{slug}"}
                class="btn btn-ghost btn-xs"
                data-follow-control
                data-unfollow-control={
                  !!BrusselsWtfWeb.FollowControl.find(@citizen_follows, "commune", slug)
                }
              >{if BrusselsWtfWeb.FollowControl.find(@citizen_follows, "commune", slug),
                do: BrusselsWtfWeb.FollowControl.text(@locale, :unfollow),
                else: text(@locale, :follow)}</button>
              <span
                :if={BrusselsWtfWeb.FollowControl.find(@citizen_follows, "commune", slug)}
                class="text-sm"
                data-followed-state
              >{BrusselsWtfWeb.FollowControl.text(@locale, :following)}</span>
            </div>
          </div>
        </details>
        <section
          :if={@directory? and (@mandates != [] or @page > 1)}
          class="mt-8 border-t border-base-300 pt-5"
          aria-labelledby="verified-mandates"
        >
          <h2 id="verified-mandates" class="sr-only">{text(@locale, :verified_mandates)}</h2>
          <ul class="mt-3 space-y-3 text-sm">
            <li :for={mandate <- @mandates}>
              <a
                class="underline underline-offset-2"
                href={"/people/#{mandate.subject_id}?lang=#{@locale}#fact-#{mandate.fact_id}"}
              >
                {mandate.subject_name}
              </a>
              <p class="mt-1">{BrusselsWtfWeb.PublicMandate.role_label(@locale, mandate)}</p>
              <p class="mt-1">{mandate.object_name}</p>
              <BrusselsWtfWeb.PublicMandate.installation_period
                :if={mandate.state == :documented}
                relationship={mandate}
                locale={@locale}
              />
              <p :if={mandate.state != :documented} class="mt-1 text-base-content/70">
                <time
                  :if={mandate.effective_from}
                  datetime={Date.to_iso8601(mandate.effective_from)}
                >
                  {Date.to_iso8601(mandate.effective_from)}
                </time>
                <span :if={mandate.effective_from && mandate.effective_to}> – </span>
                <time :if={mandate.effective_to} datetime={Date.to_iso8601(mandate.effective_to)}>
                  {Date.to_iso8601(mandate.effective_to)}
                </time>
              </p>
              <a
                class="mt-1 inline-block underline underline-offset-2"
                rel="external"
                href={
                  BrusselsWtfWeb.PublicEvidence.citation_href(%{
                    citation_url: mandate.authoritative_url,
                    location: mandate.evidence_location
                  })
                }
              >
                {text(@locale, :source)}
              </a>
            </li>
          </ul>
          <.pager
            :if={@directory? and (@page > 1 or @more_mandates?)}
            label={text(@locale, :mandates_pages)}
            page={@page}
            more?={@more_mandates?}
            locale={@locale}
            selected={@selected_communes}
            q={@q}
            path={@resource_path}
          />
        </section>
        <p :if={@directory? and @mandates == []} class="mt-8 text-base-content/80">
          {text(@locale, :none_mandates)}
        </p>
        <section
          :if={@contested?}
          id="contested-votes"
          class="mt-8 border-t border-base-300 pt-5"
          aria-labelledby="coverage-title"
        >
          <p class="text-sm text-base-content/80">{text(@locale, :contested_intro)}</p>
          <p
            :if={@contested_rows == []}
            class="mt-3 text-base-content/80"
            data-contested-empty
          >
            {text(@locale, :none_contested)}
          </p>
          <div :if={@contested_rows != []} class="mt-3 overflow-x-auto">
            <table class="w-full text-left text-sm">
              <thead class="border-b border-base-300 text-base-content/70">
                <tr>
                  <th scope="col" class="py-2 pr-3 font-medium">{text(@locale, :commune)}</th>
                  <th scope="col" class="py-2 pr-3 font-medium">{text(@locale, :meeting_date)}</th>
                  <th scope="col" class="py-2 pr-3 font-medium">{text(@locale, :item)}</th>
                  <th scope="col" class="py-2 pr-3 font-medium">{text(@locale, :decision)}</th>
                  <th scope="col" class="py-2 pr-3 text-right font-medium">
                    {text(@locale, :votes_for)}
                  </th>
                  <th scope="col" class="py-2 pr-3 text-right font-medium">
                    {text(@locale, :votes_against)}
                  </th>
                  <th scope="col" class="py-2 text-right font-medium">
                    {text(@locale, :votes_abstentions)}
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-300">
                <tr :for={row <- @contested_rows} data-commune={row.commune_slug}>
                  <td class="py-2 pr-3 align-top">{row.commune}</td>
                  <td class="py-2 pr-3 align-top tabular-nums">
                    <time datetime={Date.to_iso8601(row.date)}>{format_date(row.date)}</time>
                  </td>
                  <td class="py-2 pr-3 align-top">
                    <a href={row.href} class="underline underline-offset-2">{row.title}</a>
                  </td>
                  <td class="py-2 pr-3 align-top">
                    {BrusselsWtfWeb.DispositionLabels.label(@locale, row.disposition)}
                  </td>
                  <td class="py-2 pr-3 text-right align-top tabular-nums">{count_cell(row.for)}</td>
                  <td class={[
                    "py-2 pr-3 text-right align-top tabular-nums",
                    (row.against || 0) > 0 && "font-semibold text-error"
                  ]}>
                    {count_cell(row.against)}
                  </td>
                  <td class={[
                    "py-2 text-right align-top tabular-nums",
                    (row.abstentions || 0) > 0 && "font-semibold text-warning"
                  ]}>
                    {count_cell(row.abstentions)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <.pager
            :if={@page > 1 or @more_contested?}
            label={text(@locale, :contested_pages)}
            page={@page}
            more?={@more_contested?}
            locale={@locale}
            selected={@selected_communes}
            q={@q}
            path={@resource_path}
          />
        </section>
      </div>

      <section
        :for={category <- @categories}
        aria-labelledby={if @homepage?, do: category.id, else: "coverage-title"}
        class="mt-8 border-t border-base-300 pt-4"
      >
        <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
          <h2 :if={@homepage?} id={category.id} class="text-xl sm:text-2xl font-semibold">
            {text(@locale, category.label)}
          </h2>
          <a
            :if={@homepage?}
            href={category.href}
            class="inline-flex min-h-11 items-center text-sm underline underline-offset-2"
            aria-label={text(@locale, :view_all) <> ": " <> text(@locale, category.label)}
          >{text(@locale, :view_all)}</a>
        </div>
        <p :if={category.entries == []} class="mt-3 text-base-content/80">
          {text(@locale, category.empty)}
        </p>
        <div class="mt-2">
          <.timeline_entry :for={entry <- category.entries} entry={entry} locale={@locale} />
        </div>
      </section>
      <nav class="mt-8 border-t border-base-300 pt-4 text-sm" aria-label={text(@locale, :explore)}>
        <ul class="flex flex-wrap gap-x-6 gap-y-2">
          <li :if={not @directory?}>
            <a
              class="inline-flex min-h-11 items-center underline underline-offset-2"
              href={@directory_path}
            >{text(@locale, :verified_mandates)}</a>
          </li>
          <li :if={not @contested?}>
            <a
              class="inline-flex min-h-11 items-center underline underline-offset-2"
              href={@contested_path}
            >{text(@locale, :contested_votes)}</a>
          </li>
          <li>
            <a
              class="inline-flex min-h-11 items-center underline underline-offset-2"
              href={"/feed?lang=" <> @locale}
            >{text(@locale, :your_follows)}</a>
          </li>
          <li :for={category <- categories()} :if={not @homepage?}>
            <a
              class="inline-flex min-h-11 items-center underline underline-offset-2"
              href={selection_path(category.path, @locale, @selected_communes)}
            >{text(@locale, category.label)}</a>
          </li>
        </ul>
      </nav>

      <BrusselsWtfWeb.PublicationComponents.footer locale={@locale} />
    </main>
    """
  end

  attr :label, :string, required: true
  attr :page, :integer, required: true
  attr :more?, :boolean, required: true
  attr :locale, :string, required: true
  attr :selected, :list, required: true
  attr :q, :string, required: true
  attr :path, :string, required: true

  def pager(assigns) do
    ~H"""
    <nav class="mt-5 flex flex-wrap items-center gap-x-6 gap-y-2 text-sm" aria-label={@label}>
      <a
        :if={@page > 1}
        rel="prev"
        href={page_path(@path, @locale, @selected, @q, @page - 1)}
        class="inline-flex min-h-11 items-center underline underline-offset-2"
      >{text(@locale, :previous_page)}</a>
      <a
        :if={@more?}
        rel="next"
        href={page_path(@path, @locale, @selected, @q, @page + 1)}
        class="inline-flex min-h-11 items-center underline underline-offset-2"
      >{text(@locale, :next_page)}</a>
    </nav>
    """
  end

  defp page_path(path, locale, selected, q, page) do
    base = selection_path(path, locale, selected, q)
    if page > 1, do: base <> "&page=#{page}", else: base
  end

  defp page_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page >= 1 -> page
      _ -> 1
    end
  end

  defp page_number(_value), do: 1

  attr :entry, :map, required: true
  attr :locale, :string, required: true

  defp timeline_entry(assigns) do
    ~H"""
    <article
      class="flex flex-col sm:flex-row sm:items-baseline sm:justify-between gap-x-4 gap-y-1 border-b border-base-300 py-3"
      data-commune={@entry.commune_slug}
    >
      <a href={@entry.href} class="min-w-0 flex-1 font-medium underline-offset-2 hover:underline">
        {@entry.title}
      </a>
      <p class="shrink-0 text-sm text-base-content/70">
        {@entry.commune} ·
        <time datetime={Date.to_iso8601(@entry.date)}>{format_date(@entry.date)}</time>
        <span :if={@entry.group == :coming and @entry.date == BrusselsWtfWeb.MeetingTime.today()}> · {text(
          @locale,
          :today
        )}</span>
      </p>
    </article>
    """
  end

  attr :locale, :string, required: true
  attr :path, :string, required: true

  defp language_nav(assigns) do
    ~H"""
    <nav aria-label="Language">
      <ul class="flex gap-1 text-sm">
        <li :for={{code, label} <- [{"fr", "FR"}, {"nl", "NL"}, {"en", "EN"}]}>
          <a
            href={@path <> if(String.ends_with?(@path, "?"), do: "lang=", else: "&lang=") <> code}
            lang={code}
            hreflang={code}
            aria-current={if code == @locale, do: "page"}
            class="inline-flex min-h-11 min-w-9 items-center justify-center underline underline-offset-2"
          >{label}</a>
        </li>
      </ul>
    </nav>
    """
  end

  defp entry(%{page: page, item: item, variant: variant, state: state}, locale, selected) do
    variant = variant || unavailable_coverage_variant(locale)
    decision = loaded_or_nil(item.published_decision)

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
      group: BrusselsWtfWeb.MeetingTime.group(state, page.council_meeting.scheduled_on),
      disposition: decision && decision.disposition,
      outcome: item.published_outcome || :unknown,
      evidences: BrusselsWtfWeb.PublicEvidence.for_item(item),
      dossiers: Enum.map(item.dossier_links, & &1.dossier),
      href:
        selection_path(
          "/meetings/#{page.council_meeting.commune.slug}/#{page.council_meeting.municipal_identifier}",
          locale,
          selected
        ) <> "##{item.stable_anchor}"
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

  defp localized_summary(variant, :decision, locale),
    do: variant.decision_summary || text(locale, :decision_copy_unavailable)

  defp localized_summary(variant, _state, _locale),
    do: variant.proposal_summary || variant.summary

  defp categories do
    [
      %{
        path: "/coverage/coming-up",
        id: "coming-up",
        group: :coming,
        label: :coming,
        empty: :none_coming
      },
      %{
        path: "/coverage/awaiting-outcome",
        id: "awaiting-outcome",
        group: :awaiting,
        label: :awaiting,
        empty: :none_awaiting
      },
      %{
        path: "/coverage/decisions",
        id: "previously",
        group: :decided,
        label: :previously,
        empty: :none_decided
      }
    ]
  end

  defp selection_path(path, locale, selected, q \\ "") do
    params = %{"communes_submitted" => "1", "commune" => selected}
    params = if locale, do: Map.put(params, "lang", locale), else: params
    params = if q == "", do: params, else: Map.put(params, "q", q)
    path <> "?" <> Plug.Conn.Query.encode(params)
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

  defp loaded_or_nil(%Ash.NotLoaded{}), do: nil
  defp loaded_or_nil(value), do: value

  defp commune_name(locale, slug, name),
    do: BrusselsWtfWeb.CommuneLabels.name(locale, slug, name)

  defp format_date(date), do: Date.to_iso8601(date)

  defp count_cell(nil), do: "—"
  defp count_cell(value), do: value

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
      verified_mandates: "Verified public mandates",
      title: "What’s happening in your commune?",
      view_all: "View all",
      back: "Back to overview",
      reset: "Reset search",
      follow_communes: "Follow commune updates",
      your_follows: "Your follows",
      explore: "Explore coverage",
      none_mandates: "No verified public mandates in this selection.",
      intro:
        "Upcoming proposals, unresolved outcomes, and documented decisions from four Brussels communes.",
      communes: "Communes",
      follow: "Follow",
      apply: "Apply selection",
      search: "Search",
      sections: "Sections",
      today: "Scheduled today",
      coming: "Coming up",
      awaiting: "Awaiting documented outcome",
      none_awaiting: "No past proposals awaiting a documented outcome in this selection.",
      filters: "Filter coverage",
      previously: "What they decided",
      unknown_heading: "Outcome not yet documented",
      decided: "What they decided",
      none_coming: "No upcoming coverage.",
      none_decided: "No documented decisions.",
      item: "Agenda item",
      proposal: "Proposal",
      outcome_unknown: "Outcome unknown",
      decision: "Decision",
      provenance: "Content provenance",
      mandates_pages: "Mandate pages",
      previous_page: "Previous page",
      next_page: "Next page",
      contested_votes: "Contested votes",
      contested_intro: "Decisions with at least one vote against or one abstention.",
      none_contested: "No contested vote is recorded in this selection.",
      contested_pages: "Contested vote pages",
      commune: "Commune",
      meeting_date: "Meeting date",
      votes_for: "For",
      votes_against: "Against",
      votes_abstentions: "Abst.",
      source: "Source"
    }
  end

  defp fr_text do
    %{
      verified_mandates: "Mandats publics vérifiés",
      skip: "Aller au contenu",
      unavailable_title: "Contenu indisponible en français",
      item_unavailable: "Contenu du point indisponible en français",
      unavailable_explanation:
        "Aucune version française complète n’est disponible ; aucune autre langue n’est substituée.",
      decision_copy_unavailable: "Le texte de la décision n’est pas disponible en français.",
      synthetic_reference:
        "Référence de démonstration — ne constitue pas une preuve d’activité communale",
      dossiers: "Dossiers",
      title: "Que se passe-t-il dans votre commune ?",
      view_all: "Tout voir",
      back: "Retour à l’aperçu",
      reset: "Réinitialiser la recherche",
      follow_communes: "Suivre les nouvelles des communes",
      your_follows: "Vos suivis",
      explore: "Explorer l’actualité",
      none_mandates: "Aucun mandat public vérifié dans cette sélection.",
      intro:
        "Propositions à venir, résultats non documentés et décisions officielles de quatre communes bruxelloises.",
      communes: "Communes",
      follow: "Suivre",
      apply: "Appliquer la sélection",
      search: "Rechercher",
      sections: "Sections",
      today: "Prévu aujourd’hui",
      coming: "À venir",
      awaiting: "En attente d’un résultat documenté",
      none_awaiting: "Aucune proposition passée sans résultat documenté dans cette sélection.",
      filters: "Filtrer les articles",
      previously: "Ce qu’ils ont décidé",
      unknown_heading: "Résultat pas encore documenté",
      decided: "Ce qu’ils ont décidé",
      none_coming: "Aucune actualité à venir.",
      none_decided: "Aucune décision documentée.",
      item: "Point",
      proposal: "Proposition",
      outcome_unknown: "Résultat inconnu",
      decision: "Décision",
      provenance: "Provenance du contenu",
      mandates_pages: "Pages de mandats",
      previous_page: "Page précédente",
      next_page: "Page suivante",
      contested_votes: "Votes contestés",
      contested_intro: "Décisions ayant recueilli au moins un vote contre ou une abstention.",
      none_contested: "Aucun vote contesté n’est documenté dans cette sélection.",
      contested_pages: "Pages de votes contestés",
      commune: "Commune",
      meeting_date: "Date de la séance",
      votes_for: "Pour",
      votes_against: "Contre",
      votes_abstentions: "Abst.",
      source: "Source"
    }
  end

  defp nl_text do
    %{
      verified_mandates: "Geverifieerde openbare mandaten",
      skip: "Naar inhoud",
      unavailable_title: "Inhoud niet beschikbaar in het Nederlands",
      item_unavailable: "Inhoud van het agendapunt niet beschikbaar in het Nederlands",
      unavailable_explanation:
        "Er is geen volledige Nederlandse versie beschikbaar; een andere taal wordt niet ingevoegd.",
      decision_copy_unavailable: "De beslissingstekst is niet beschikbaar in het Nederlands.",
      synthetic_reference: "Demonstratiereferentie — geen bewijs van gemeentelijke activiteit",
      dossiers: "Dossiers",
      title: "Wat gebeurt er in uw gemeente?",
      view_all: "Alles bekijken",
      back: "Terug naar het overzicht",
      reset: "Zoekopdracht wissen",
      follow_communes: "Gemeentenieuws volgen",
      your_follows: "Uw gevolgde updates",
      explore: "Berichtgeving verkennen",
      none_mandates: "Geen geverifieerde openbare mandaten in deze selectie.",
      intro:
        "Komende voorstellen, niet-gedocumenteerde resultaten en officiële besluiten uit vier Brusselse gemeenten.",
      communes: "Gemeenten",
      follow: "Volgen",
      apply: "Selectie toepassen",
      search: "Zoeken",
      sections: "Onderdelen",
      today: "Vandaag gepland",
      coming: "Binnenkort",
      awaiting: "In afwachting van een gedocumenteerde uitkomst",
      none_awaiting: "Geen eerdere voorstellen zonder gedocumenteerde uitkomst in deze selectie.",
      filters: "Berichten filteren",
      previously: "Wat ze besloten",
      unknown_heading: "Resultaat nog niet gedocumenteerd",
      decided: "Wat ze beslisten",
      none_coming: "Geen komende berichtgeving.",
      none_decided: "Geen gedocumenteerde besluiten.",
      item: "Agendapunt",
      proposal: "Voorstel",
      outcome_unknown: "Resultaat onbekend",
      decision: "Besluit",
      provenance: "Herkomst van de inhoud",
      mandates_pages: "Mandatenpagina's",
      previous_page: "Vorige pagina",
      next_page: "Volgende pagina",
      contested_votes: "Betwiste stemmingen",
      contested_intro: "Besluiten met minstens één tegenstem of onthouding.",
      none_contested: "In deze selectie is geen betwiste stemming gedocumenteerd.",
      contested_pages: "Pagina's met betwiste stemmingen",
      commune: "Gemeente",
      meeting_date: "Datum van de zitting",
      votes_for: "Voor",
      votes_against: "Tegen",
      votes_abstentions: "Onth.",
      source: "Bron"
    }
  end
end
