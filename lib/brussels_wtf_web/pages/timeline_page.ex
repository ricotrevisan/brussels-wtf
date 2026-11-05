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
    meetings_index? = path == "/meetings"
    contested? = path == "/coverage/contested-votes"
    category = Enum.find(categories(), &(&1.path == path))

    q = if homepage? or contested? or meetings_index?, do: "", else: search_query(params["q"])

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
          groups:
            cond do
              homepage? -> [:coming, :awaiting, :decided]
              meetings_index? -> []
              true -> [category.group]
            end,
          limit: if(homepage?, do: 5),
          balance: homepage?
        )
      end

    page = if homepage? or meetings_index?, do: 1, else: page_number(params["page"])

    mandates =
      if directory? do
        BrusselsWtf.Identity.list_public_mandates!(selected, q, page)
      else
        %{mandates: [], more?: false}
      end

    contested =
      if contested? or homepage? do
        Council.list_contested_decisions!(selected, page)
      else
        %{items: [], more?: false}
      end

    assign(BrusselsWtfWeb.FollowControl.load(conn),
      page_title: text(locale, title_key(directory?, contested?, category, meetings_index?)),
      html_lang: locale,
      resource_path: path,
      meta_description: BrusselsWtfWeb.PublicDescription.fixed(description_key(path), locale),
      homepage?: homepage?,
      directory?: directory?,
      contested?: contested?,
      title: text(locale, title_key(directory?, contested?, category, meetings_index?)),
      meetings_index?: meetings_index?,
      tracked_meetings: matching |> Map.get(:meetings, []) |> length(),
      tracked_items:
        matching
        |> Map.get(:meetings, [])
        |> Enum.map(fn page -> Enum.count(page.council_meeting.agenda_items, & &1.published?) end)
        |> Enum.sum(),
      meeting_rows:
        matching
        |> Map.get(:meetings, [])
        |> Enum.map(&meeting_row(&1, locale))
        |> then(fn rows ->
          if homepage?, do: Enum.uniq_by(rows, & &1.commune_slug), else: rows
        end),
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
      lead: lead_key(path) && text(locale, lead_key(path)),
      result_line: result_line(locale, selected, matching, category, page),
      selection_query:
        Plug.Conn.Query.encode(%{"communes_submitted" => "1", "commune" => selected}),
      more_results?: more_results?(matching, category, page),
      categories:
        sections(
          homepage?,
          category,
          paged(matching, category, page),
          Enum.take(contested.items, 3),
          locale,
          selected
        )
    )
  end

  defp lead_key("/coverage/coming-up"), do: :lead_coming
  defp lead_key("/coverage/awaiting-outcome"), do: :lead_awaiting
  defp lead_key("/coverage/decisions"), do: :lead_decided
  defp lead_key("/coverage/contested-votes"), do: :contested_intro
  defp lead_key("/meetings"), do: :lead_meetings
  defp lead_key(_path), do: nil

  @list_page_size 25

  defp paged(matching, nil, _page), do: matching

  defp paged(matching, category, page) do
    Map.update!(
      matching,
      category.group,
      &Enum.slice(&1, (page - 1) * @list_page_size, @list_page_size)
    )
  end

  defp more_results?(_matching, nil, _page), do: false

  defp more_results?(matching, category, page),
    do: length(Map.fetch!(matching, category.group)) > page * @list_page_size

  defp result_line(_locale, _selected, _matching, nil, _page), do: nil

  defp result_line(locale, selected, matching, category, page) do
    count = matching |> Map.fetch!(category.group) |> length()
    names = Enum.map(selected, fn slug -> commune_name(locale, slug, commune_label(slug)) end)

    scope =
      cond do
        names == [] -> nil
        length(names) == length(@communes) -> text(locale, :all_communes)
        true -> Enum.join(names, ", ")
      end

    pages = max(ceil(count / @list_page_size), 1)

    [
      String.replace(text(locale, :results), "%{count}", Integer.to_string(count)),
      scope,
      if(pages > 1, do: "#{text(locale, :page)} #{page}/#{pages}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp commune_label(slug), do: @communes |> List.keyfind!(slug, 0) |> elem(1)

  # The homepage leads with documented outcomes; empty sections shrink to one line at the end.
  defp sections(homepage?, category, matching, contested, locale, selected) do
    rows =
      categories()
      |> Enum.filter(&(homepage? or &1 == category))
      |> Enum.map(fn category ->
        entries = Map.fetch!(matching, category.group) |> Enum.map(&entry(&1, locale, selected))

        Map.merge(category, %{
          entries: entries,
          lead:
            if(category.path == "/coverage/decisions",
              do: :lead_decided_home,
              else: lead_key(category.path)
            ),
          href: selection_path(category.path, locale, selected)
        })
      end)

    if homepage? do
      contested_section = %{
        path: "/coverage/contested-votes",
        id: "contested",
        group: :decided,
        label: :contested_votes,
        empty: :none_contested,
        lead: :contested_intro,
        href: selection_path("/coverage/contested-votes", locale, selected),
        entries: Enum.map(contested, &contested_entry(&1, locale, selected))
      }

      by_id = Map.new(rows, &{&1.id, &1})

      [by_id["coming-up"], by_id["previously"], contested_section, by_id["awaiting-outcome"]]
      |> Enum.sort_by(&(&1.entries == []))
    else
      rows
    end
  end

  defp contested_entry(item, locale, selected) do
    row = contested_row(item, locale, selected)

    %{
      commune: row.commune,
      commune_slug: row.commune_slug,
      date: row.date,
      item_number: item.published_item_number || item.item_number,
      title: row.title,
      headline: row.headline,
      summary: nil,
      group: :decided,
      disposition: row.disposition,
      contested?: true,
      vote_line: vote_line(item.published_decision, locale),
      topic_source: item.source_wording,
      votes: {row.for, row.against, row.abstentions},
      href: row.href
    }
  end

  defp meeting_row(page, locale) do
    meeting = page.council_meeting
    items = Enum.filter(meeting.agenda_items, & &1.published?)
    decided = Enum.count(items, &loaded_or_nil(&1.published_decision))
    variant = Enum.find(page.locale_variants, &(&1.locale == locale))

    %{
      commune: commune_name(locale, meeting.commune.slug, meeting.commune.name),
      commune_slug: meeting.commune.slug,
      date: meeting.scheduled_on,
      title: variant && variant.title,
      href: "/meetings/#{meeting.commune.slug}/#{meeting.municipal_identifier}?lang=#{locale}",
      total: length(items),
      decided: decided,
      unknown: length(items) - decided,
      highlight: highlight(items, locale)
    }
  end

  # The first non-routine agenda item, shown so each meeting card says something of its own.
  defp highlight(items, locale) do
    items
    |> Enum.sort_by(fn item ->
      case Integer.parse(item.published_item_number || item.item_number || "") do
        {value, ""} -> value
        _ -> 1_000_000
      end
    end)
    |> Enum.reject(&BrusselsWtf.Council.PublicTimeline.routine_item?/1)
    |> Enum.find_value(fn item ->
      case Enum.find(item.coverage_variants, &(&1.locale == locale)) do
        nil -> nil
        variant -> variant.headline || variant.title
      end
    end)
  end

  defp description_key("/"), do: :home
  defp description_key("/meetings"), do: :meetings
  defp description_key("/mandates"), do: :mandates
  defp description_key("/coverage/contested-votes"), do: :contested_votes
  defp description_key("/coverage/coming-up"), do: :coming_up
  defp description_key("/coverage/awaiting-outcome"), do: :awaiting_outcome
  defp description_key("/coverage/decisions"), do: :decisions

  defp title_key(_directory?, _contested?, _category, true), do: :meetings
  defp title_key(true, _contested?, _category, _meetings?), do: :verified_mandates
  defp title_key(_directory?, true, _category, _meetings?), do: :contested_votes

  defp title_key(_directory?, _contested?, category, _meetings?),
    do: (category && category.label) || :title

  defp contested_row(item, locale, selected) do
    meeting = item.council_meeting
    decision = item.published_decision
    variant = Enum.find(item.coverage_variants, &(&1.locale == locale))

    %{
      commune: commune_name(locale, meeting.commune.slug, meeting.commune.name),
      commune_slug: meeting.commune.slug,
      date: meeting.scheduled_on,
      title: if(variant, do: variant.title, else: text(locale, :item_unavailable)),
      headline: variant && variant.headline,
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
    <BrusselsWtfWeb.PublicShell.header
      locale={@locale}
      home_href={@home_path}
      current={@resource_path}
      selection={@selection_query}
      lang_href={fn code -> @language_path <> "&lang=" <> code end}
    />

    <main id="content" class="reader-coverage text-base-content" tabindex="-1">
      <div :if={@homepage?} class="hero-band" data-tracked={@tracked_items}>
        <div class="site-container hero-grid py-4 sm:py-10">
          <div>
            <h1 id="coverage-title" class="display display-xl measure">{@title}</h1>
            <p class="measure mt-3 text-base leading-6 sm:text-lg sm:leading-6">
              {text(@locale, :intro)}
              <span :if={@tracked_items > 0} class="hidden font-semibold sm:inline">
                {tracking_line(@locale, @tracked_meetings, @tracked_items)}
              </span>
            </p>
            <.commune_form
              communes={@communes}
              selected={@selected_communes}
              locale={@locale}
              path={@resource_path}
              homepage?={true}
              contested?={false}
              q=""
            />
          </div>
          <span class="hero-sticker" aria-hidden="true">
            <img src={~p"/images/brand/icon-dark.svg"} alt="" width="200" height="200" />
          </span>
        </div>
      </div>

      <div class="site-container">
        <div :if={not @homepage?} class="pt-5 sm:pt-7">
          <h1 id="coverage-title" class="display display-lg">{@title}</h1>
          <p :if={@lead} class="measure muted mt-2">{@lead}</p>
          <form
            :for={{slug, _name} <- @communes}
            id={"follow-commune-#{slug}"}
            method="post"
            action={BrusselsWtfWeb.FollowControl.action(BrusselsWtfWeb.FollowControl.find(@citizen_follows, "commune", slug)) <> "?lang=" <> @locale}
          >
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <input type="hidden" name="target_type" value="commune" />
            <input type="hidden" name="target_identifier" value={slug} />
          </form>
          <p :if={map_size(@citizen_follows) > 0} class="mt-2 text-sm">
            {BrusselsWtfWeb.FollowControl.text(@locale, :history)}
          </p>
          <.commune_form
            communes={@communes}
            selected={@selected_communes}
            locale={@locale}
            path={@resource_path}
            homepage?={false}
            contested?={@contested? or @meetings_index?}
            q={@q}
            reset_path={@reset_path}
          />
          <details class="reader-filters disclosure mt-1">
            <summary>
              <span class="hero-bell-micro size-4" aria-hidden="true"></span>{text(
                @locale,
                :follow_communes
              )}
            </summary>
            <div class="disclosure-body grid gap-x-6 gap-y-1 sm:grid-cols-2">
              <div :for={{slug, name} <- @communes} class="flex items-center justify-between gap-2">
                <span>{name}</span>
                <span class="flex items-center gap-2">
                  <span
                    :if={BrusselsWtfWeb.FollowControl.find(@citizen_follows, "commune", slug)}
                    class="text-sm"
                    data-followed-state
                  >{BrusselsWtfWeb.FollowControl.text(@locale, :following)}</span>
                  <button
                    type="submit"
                    form={"follow-commune-#{slug}"}
                    class="btn btn-sm min-h-11"
                    data-follow-control
                    data-unfollow-control={
                      !!BrusselsWtfWeb.FollowControl.find(@citizen_follows, "commune", slug)
                    }
                  >{if BrusselsWtfWeb.FollowControl.find(@citizen_follows, "commune", slug),
                    do: BrusselsWtfWeb.FollowControl.text(@locale, :unfollow),
                    else: text(@locale, :follow)}</button>
                </span>
              </div>
            </div>
          </details>
          <p :if={@result_line} class="mt-3 text-sm font-semibold" role="status" data-result-count>
            {@result_line}
          </p>
        </div>

        <BrusselsWtfWeb.PublicShell.ai_key
          :if={Enum.any?(@categories, fn c -> Enum.any?(c.entries, & &1[:headline]) end)}
          locale={@locale}
        />

        <section :if={@meetings_index?} class="mt-4" data-meeting-index>
          <p :if={@meeting_rows == []} class="callout mt-3">{text(@locale, :none_selected)}</p>
          <ul class="border-t border-base-300">
            <li :for={row <- @meeting_rows} class="entry" data-commune={row.commune_slug}>
              <a href={row.href} class="entry-title">
                {row.commune} ·
                <time datetime={Date.to_iso8601(row.date)}>{format_date(row.date, @locale)}</time>
              </a>
              <p class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm">
                <span class="muted">{item_count(row, @locale)}</span>
                <BrusselsWtfWeb.PublicShell.status
                  :if={row.decided == 0}
                  kind={:unknown}
                  label={text(@locale, :outcome_unknown)}
                />
                <BrusselsWtfWeb.PublicShell.status
                  :if={row.decided > 0}
                  kind={:decided}
                  label={decided_count(row, @locale)}
                />
              </p>
            </li>
          </ul>
        </section>

        <p :if={@homepage? and @selected_communes == []} class="callout mt-6" data-none-selected>
          {text(@locale, :none_selected)}
        </p>

        <section
          :if={@directory? and (@mandates != [] or @page > 1)}
          class="mt-4"
          aria-labelledby="verified-mandates"
        >
          <h2 id="verified-mandates" class="sr-only">{text(@locale, :verified_mandates)}</h2>
          <ul class="border-t border-base-300">
            <li :for={mandate <- @mandates} class="entry">
              <a
                class="entry-title"
                href={"/people/#{mandate.subject_id}?lang=#{@locale}#fact-#{mandate.fact_id}"}
              >
                {mandate.subject_name}
              </a>
              <p class="mt-1">{BrusselsWtfWeb.PublicMandate.role_label(@locale, mandate)}</p>
              <p class="muted mt-1 text-sm">{mandate.object_name}</p>
              <BrusselsWtfWeb.PublicMandate.installation_period
                :if={mandate.state == :documented}
                relationship={mandate}
                locale={@locale}
              />
              <p :if={mandate.state != :documented} class="muted mt-1 text-sm">
                <time
                  :if={mandate.effective_from}
                  datetime={Date.to_iso8601(mandate.effective_from)}
                >
                  {format_date(mandate.effective_from, @locale)}
                </time>
                <span :if={mandate.effective_from && mandate.effective_to}> – </span>
                <time :if={mandate.effective_to} datetime={Date.to_iso8601(mandate.effective_to)}>
                  {format_date(mandate.effective_to, @locale)}
                </time>
              </p>
              <a
                class="mt-1 inline-flex min-h-11 items-center gap-1 text-sm"
                rel="external"
                href={
                  BrusselsWtfWeb.PublicEvidence.citation_href(%{
                    citation_url: mandate.authoritative_url,
                    location: mandate.evidence_location
                  })
                }
              >
                <span class="hero-document-text-micro size-4" aria-hidden="true"></span>{text(
                  @locale,
                  :source
                )}
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
        <p :if={@directory? and @mandates == []} class="callout mt-6">
          {text(@locale, :none_mandates)}
        </p>

        <section
          :if={@contested?}
          id="contested-votes"
          class="mt-4"
          aria-labelledby="coverage-title"
        >
          <p
            :if={@contested_rows == []}
            class="callout mt-3"
            data-contested-empty
          >
            {text(@locale, :none_contested)}
          </p>
          <div :if={@contested_rows != []} class="mt-3">
            <BrusselsWtfWeb.PublicShell.vote_legend locale={@locale} />
            <table class="data-table mt-3">
              <thead>
                <tr>
                  <th scope="col">{text(@locale, :item)}</th>
                  <th scope="col">{text(@locale, :commune)}</th>
                  <th scope="col">{text(@locale, :meeting_date)}</th>
                  <th scope="col">{text(@locale, :decision)}</th>
                  <th scope="col" class="num">{text(@locale, :votes_for)}</th>
                  <th scope="col" class="num">{text(@locale, :votes_against)}</th>
                  <th scope="col" class="num">{text(@locale, :votes_abstentions)}</th>
                  <th scope="col"><span class="sr-only">{text(@locale, :vote_split)}</span></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @contested_rows} data-commune={row.commune_slug}>
                  <td class="cell-lead">
                    <a href={row.href} class="entry-title">
                      <BrusselsWtfWeb.PublicShell.ai_mark :if={row.headline} locale={@locale} />{row.headline ||
                        row.title}
                    </a>
                  </td>
                  <td data-label={text(@locale, :commune)}>{row.commune}</td>
                  <td data-label={text(@locale, :meeting_date)}>
                    <time datetime={Date.to_iso8601(row.date)}>{format_date(row.date, @locale)}</time>
                  </td>
                  <td data-label={text(@locale, :decision)}>
                    {String.capitalize(
                      BrusselsWtfWeb.DispositionLabels.label(@locale, row.disposition)
                    )}
                  </td>
                  <td class="num" data-label={text(@locale, :votes_for)}>{count_cell(row.for)}</td>
                  <td
                    class={["num", (row.against || 0) > 0 && "vote-against"]}
                    data-label={text(@locale, :votes_against)}
                  >
                    {count_cell(row.against)}
                  </td>
                  <td
                    class={["num", (row.abstentions || 0) > 0 && "vote-abstain"]}
                    data-label={text(@locale, :votes_abstentions)}
                  >
                    {count_cell(row.abstentions)}
                  </td>
                  <td class="cell-bar">
                    <BrusselsWtfWeb.PublicShell.vote_split
                      for_votes={row.for}
                      against={row.against}
                      abstentions={row.abstentions}
                      locale={@locale}
                      label={false}
                    />
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

        <section
          :for={category <- @categories}
          :if={not (@homepage? and @selected_communes == [])}
          aria-labelledby={if @homepage?, do: category.id, else: "coverage-title"}
          class={[
            if(@homepage? and category.entries == [], do: "mt-4", else: "mt-8 sm:mt-10")
          ]}
          data-section={category.id}
        >
          <%= if @homepage? and category.entries == [] do %>
            <div class="flex flex-wrap items-center justify-between gap-x-4 border-y border-base-300 py-2">
              <h2 id={category.id} class="text-base font-semibold">
                {text(@locale, category.label)}
              </h2>
              <p class="muted min-w-0 flex-1 text-sm">{text(@locale, category.empty)}</p>
              <a
                href={category.href}
                class="inline-flex min-h-11 items-center text-sm"
                aria-label={text(@locale, :view_all) <> ": " <> text(@locale, category.label)}
              >
                {text(@locale, :view_all)}<span
                  class="hero-arrow-right-micro ml-1 size-4"
                  aria-hidden="true"
                ></span>
              </a>
            </div>
          <% else %>
            <div
              :if={@homepage?}
              class="flex flex-wrap items-end justify-between gap-x-4 border-b-2 border-base-content pb-1"
            >
              <h2 id={category.id} class="display display-md">{text(@locale, category.label)}</h2>
              <a
                href={category.href}
                class="inline-flex min-h-11 items-center gap-1 text-sm font-medium"
                aria-label={text(@locale, :view_all) <> ": " <> text(@locale, category.label)}
              >
                {text(@locale, :view_all)}<span
                  class="hero-arrow-right-micro size-4"
                  aria-hidden="true"
                ></span>
              </a>
            </div>
            <p :if={@homepage? and category[:lead]} class="measure muted mt-2 text-sm">
              {text(@locale, category.lead)}
            </p>
            <p :if={category.entries == []} class="callout mt-3">
              {text(@locale, category.empty)}
            </p>
            <div :if={@homepage?}>
              <.timeline_entry :for={entry <- category.entries} entry={entry} locale={@locale} />
            </div>
            <div :if={not @homepage?}>
              <section
                :for={group <- meeting_groups(category.entries)}
                class="mt-5"
                data-meeting-group
              >
                <h2 class="flex flex-wrap items-baseline gap-x-2 border-b-2 border-base-content pb-1">
                  <a href={group.href} class="link-quiet text-base font-semibold">{group.commune}</a>
                  <time class="muted text-sm" datetime={Date.to_iso8601(group.date)}>
                    {format_date(group.date, @locale)}
                  </time>
                </h2>
                <.timeline_entry
                  :for={entry <- group.entries}
                  entry={entry}
                  locale={@locale}
                  grouped={true}
                />
              </section>
              <.pager
                :if={@page > 1 or @more_results?}
                label={text(@locale, :results_pages)}
                page={@page}
                more?={@more_results?}
                locale={@locale}
                selected={@selected_communes}
                q={@q}
                path={@resource_path}
              />
            </div>
          <% end %>
        </section>

        <section
          :if={@homepage? and @meeting_rows != []}
          class="mt-8 sm:mt-10"
          aria-labelledby="latest-meetings"
        >
          <div class="flex flex-wrap items-end justify-between gap-x-4 border-b-2 border-base-content pb-1">
            <h2 id="latest-meetings" class="display display-md">{text(@locale, :latest_meetings)}</h2>
            <a
              href={BrusselsWtfWeb.PublicShell.section_href("/meetings", @locale, @selection_query)}
              class="inline-flex min-h-11 items-center gap-1 text-sm font-medium"
              aria-label={text(@locale, :view_all) <> ": " <> text(@locale, :meetings)}
            >
              {text(@locale, :view_all)}<span class="hero-arrow-right-micro size-4" aria-hidden="true"></span>
            </a>
          </div>
          <ul class="meeting-cards mt-3">
            <li :for={row <- @meeting_rows}>
              <a href={row.href} class="meeting-card">
                <span class="block font-semibold">{row.commune}</span>
                <time class="block text-sm" datetime={Date.to_iso8601(row.date)}>
                  {format_date(row.date, @locale)}
                </time>
                <span :if={row.highlight} class="card-highlight muted mt-1 text-sm leading-5">
                  {row.highlight}
                </span>
                <span class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-sm">
                  <span class="muted">{item_count(row, @locale)}</span>
                  <BrusselsWtfWeb.PublicShell.status
                    :if={row.decided == 0}
                    kind={:unknown}
                    label={text(@locale, :outcome_unknown)}
                  />
                  <BrusselsWtfWeb.PublicShell.status
                    :if={row.decided > 0}
                    kind={:decided}
                    label={decided_count(row, @locale)}
                  />
                </span>
              </a>
            </li>
          </ul>
        </section>
      </div>
    </main>
    <BrusselsWtfWeb.PublicationComponents.footer locale={@locale} />
    """
  end

  attr :communes, :list, required: true
  attr :selected, :list, required: true
  attr :locale, :string, required: true
  attr :path, :string, required: true
  attr :homepage?, :boolean, required: true
  attr :contested?, :boolean, required: true
  attr :q, :string, required: true
  attr :reset_path, :string, default: nil

  defp commune_form(assigns) do
    ~H"""
    <form
      method="get"
      action={@path}
      data-reader-communes
      data-auto-submit
      class={[
        "mt-5 space-y-3",
        not @homepage? && "chips-plain",
        length(@selected) == length(@communes) && "all-on"
      ]}
    >
      <input type="hidden" name="lang" value={@locale} />
      <input type="hidden" name="communes_submitted" value="1" />
      <label :if={not @homepage? and not @contested?} class="block text-sm font-semibold">
        {text(@locale, :search)}
        <span class="mt-1 flex gap-2">
          <input type="search" name="q" value={@q} class="input input-bordered min-h-11 w-full" />
          <button type="submit" class="btn btn-neutral min-h-11">{text(@locale, :search)}</button>
        </span>
      </label>
      <fieldset>
        <legend class="mb-2 text-sm font-semibold">{text(@locale, :communes)}</legend>
        <div class="flex flex-wrap gap-2">
          <a
            :if={length(@selected) < length(@communes)}
            href={selection_path(@path, @locale, Enum.map(@communes, &elem(&1, 0)))}
            class="chip link-quiet"
            data-all-communes
          >{text(@locale, :all_communes_chip)}</a>
          <label :for={{slug, name} <- @communes} class="chip">
            <input type="checkbox" name="commune[]" value={slug} checked={slug in @selected} />
            <span class="chip-mark chip-mark-off hero-plus-micro" aria-hidden="true"></span>
            <span class="chip-mark chip-mark-on hero-check-micro" aria-hidden="true"></span>
            <span>{name}</span>
          </label>
        </div>
      </fieldset>
      <div class="filter-submit flex flex-wrap items-center gap-4">
        <button type="submit" class="btn btn-neutral min-h-11">{text(@locale, :apply)}</button>
      </div>
      <a
        :if={@reset_path && @q != ""}
        data-reader-reset
        href={@reset_path}
        class="inline-flex min-h-11 items-center text-sm"
      >{text(@locale, :reset)}</a>
    </form>
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
  attr :grouped, :boolean, default: false

  defp timeline_entry(assigns) do
    assigns =
      assigns
      |> assign(
        :amount,
        BrusselsWtfWeb.PublicShell.amount_in(assigns.entry.title, assigns.locale)
      )
      |> assign(
        :topic,
        BrusselsWtfWeb.PublicShell.topic_of(assigns.entry[:topic_source] || assigns.entry.title)
      )

    ~H"""
    <article class="entry" data-commune={@entry.commune_slug} data-group={@entry.group}>
      <div class="min-w-0">
        <BrusselsWtfWeb.PublicShell.kicker
          topic={@topic}
          amount={if(!@entry[:headline], do: @amount)}
          locale={@locale}
        />
        <a href={@entry.href} class={["entry-title", @entry[:headline] && "has-headline"]}>
          <BrusselsWtfWeb.PublicShell.title_parts
            title={@entry.title}
            headline={@entry[:headline]}
            locale={@locale}
          />
        </a>
        <p
          :if={!@entry[:headline] and show_summary?(@entry)}
          class="entry-summary measure muted mt-1 text-sm leading-5"
        >
          {@entry.summary}
        </p>
      </div>
      <p class="entry-meta flex flex-wrap items-center gap-x-3 gap-y-1 text-sm">
        <BrusselsWtfWeb.PublicShell.status
          kind={status_kind(@entry)}
          label={status_label(@entry, @locale)}
        />
        <BrusselsWtfWeb.PublicShell.vote_split
          :if={@entry.contested?}
          for_votes={elem(@entry.votes, 0)}
          against={elem(@entry.votes, 1)}
          abstentions={elem(@entry.votes, 2)}
          locale={@locale}
        />
        <span class="muted w-full">
          <span :if={not @grouped} class="font-medium">{@entry.commune} · </span>
          <time :if={not @grouped} datetime={Date.to_iso8601(@entry.date)}>
            {format_date(@entry.date, @locale)}
          </time>
          <span :if={not @grouped and @entry.item_number}> · </span>
          <span :if={@entry.item_number}>{text(@locale, :item)} {@entry.item_number}</span>
          <span :if={@entry.group == :coming and @entry.date == BrusselsWtfWeb.MeetingTime.today()}>
            · {text(@locale, :today)}
          </span>
        </span>
        <span
          :if={@entry.vote_line}
          class={[(@entry.contested? && "font-semibold") || "muted"]}
          data-vote-line
        >{@entry.vote_line}</span>
      </p>
    </article>
    """
  end

  defp meeting_groups(entries) do
    entries
    |> Enum.chunk_by(&{&1.commune_slug, &1.date})
    |> Enum.map(fn [first | _] = group ->
      %{
        commune: first.commune,
        date: first.date,
        href: first.href |> String.split("#") |> hd(),
        entries: group
      }
    end)
  end

  defp show_summary?(%{summary: summary, title: title}) when is_binary(summary),
    do: String.length(summary) > 40 and String.jaro_distance(summary, title) < 0.85

  defp show_summary?(_entry), do: false

  defp status_kind(%{group: :coming}), do: :coming
  defp status_kind(%{group: :awaiting}), do: :awaiting
  defp status_kind(%{disposition: disposition}) when not is_nil(disposition), do: disposition
  defp status_kind(_entry), do: :decided

  defp status_label(%{group: :coming}, locale), do: text(locale, :proposal)
  defp status_label(%{group: :awaiting}, locale), do: text(locale, :outcome_unknown)

  defp status_label(%{disposition: disposition}, locale) when not is_nil(disposition),
    do: String.capitalize(BrusselsWtfWeb.DispositionLabels.label(locale, disposition))

  defp status_label(_entry, locale), do: text(locale, :decision)

  defp vote_line(nil, _locale), do: nil

  defp vote_line(decision, locale) do
    BrusselsWtfWeb.PublicShell.vote_text(
      locale,
      decision.votes_for,
      decision.votes_against,
      decision.abstentions
    )
  end

  defp contested?(nil), do: false

  defp contested?(decision),
    do: (decision.votes_against || 0) > 0 or (decision.abstentions || 0) > 0

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
      headline: Map.get(variant, :headline),
      summary: localized_summary(variant, state, locale),
      provenance: variant.provenance,
      state: state,
      group: BrusselsWtfWeb.MeetingTime.group(state, page.council_meeting.scheduled_on),
      disposition: decision && decision.disposition,
      contested?: contested?(decision),
      vote_line: vote_line(decision, locale),
      topic_source: item.source_wording,
      votes: decision && {decision.votes_for, decision.votes_against, decision.abstentions},
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

  defp tracking_line(locale, meetings, items) do
    text(locale, :tracking)
    |> String.replace("%{meetings}", Integer.to_string(meetings))
    |> String.replace("%{items}", Integer.to_string(items))
  end

  defp item_count(row, locale),
    do: String.replace(text(locale, :results), "%{count}", Integer.to_string(row.total))

  defp decided_count(row, locale),
    do: String.replace(text(locale, :decided_count), "%{count}", Integer.to_string(row.decided))

  defp format_date(date, locale), do: BrusselsWtfWeb.PublicDate.long(date, locale)

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
      back: "Back",
      reset: "Reset search",
      follow_communes: "Follow commune updates",
      your_follows: "Personal feed",
      explore: "Explore coverage",
      none_mandates: "No verified public mandates in this selection.",
      intro:
        "Follow public spending, local works and votes in four Brussels councils, each item linked to its official document.",
      communes: "Communes",
      follow: "Follow",
      apply: "Update",
      search: "Search",
      sections: "Sections",
      today: "Scheduled today",
      coming: "Coming up",
      awaiting: "Outcome unknown",
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
      contested_votes: "Not unanimous",
      contested_intro: "Decisions with at least one vote against or one abstention.",
      none_contested: "No split vote is recorded in this selection.",
      contested_pages: "Vote result pages",
      commune: "Commune",
      meeting_date: "Meeting date",
      votes_for: "For",
      votes_against: "Against",
      votes_abstentions: "Abstained",
      all_communes_chip: "All communes",
      latest_meetings: "Latest meetings",
      decided_count: "%{count} decisions",
      tracking: "Tracking %{meetings} meetings and %{items} agenda items so far.",
      meetings: "Meetings",
      lead_meetings: "Every meeting we cover, newest first.",
      vote_split: "Vote split",
      results: "%{count} items",
      page: "Page",
      results_pages: "Result pages",
      all_communes: "all four communes",
      none_selected: "Choose at least one commune to see its coverage.",
      lead_coming: "Proposals on upcoming agendas. Nothing here has been decided yet.",
      lead_awaiting:
        "The meeting has passed, but no official record of the outcome is attached yet.",
      lead_decided_home:
        "Newest meeting first. Items naming an amount or with a split vote lead; recurring formalities come last.",
      lead_decided:
        "Outcomes documented in official records, newest meeting first, in agenda order.",
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
      back: "Retour",
      reset: "Réinitialiser la recherche",
      follow_communes: "Suivre les nouvelles des communes",
      your_follows: "Vos suivis",
      explore: "Explorer l’actualité",
      none_mandates: "Aucun mandat public vérifié dans cette sélection.",
      intro:
        "Suivez les dépenses publiques, les travaux et les votes de quatre conseils bruxellois, chaque point relié à son document officiel.",
      communes: "Communes",
      follow: "Suivre",
      apply: "Mettre à jour",
      search: "Rechercher",
      sections: "Sections",
      today: "Prévu aujourd’hui",
      coming: "À venir",
      awaiting: "Résultat inconnu",
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
      contested_votes: "Non unanimes",
      contested_intro: "Décisions ayant recueilli au moins un vote contre ou une abstention.",
      none_contested: "Aucun vote partagé n’est documenté dans cette sélection.",
      contested_pages: "Pages de résultats de vote",
      commune: "Commune",
      meeting_date: "Date de la séance",
      votes_for: "Pour",
      votes_against: "Contre",
      votes_abstentions: "Abstention",
      all_communes_chip: "Toutes les communes",
      latest_meetings: "Dernières séances",
      decided_count: "%{count} décisions",
      tracking: "%{meetings} séances et %{items} points suivis à ce jour.",
      meetings: "Séances",
      lead_meetings: "Toutes les séances couvertes, de la plus récente à la plus ancienne.",
      vote_split: "Répartition des votes",
      results: "%{count} points",
      page: "Page",
      results_pages: "Pages de résultats",
      all_communes: "les quatre communes",
      none_selected: "Choisissez au moins une commune pour voir son actualité.",
      lead_coming:
        "Propositions inscrites aux prochains ordres du jour. Rien n’est encore décidé.",
      lead_awaiting:
        "La séance a eu lieu, mais aucun document officiel du résultat n’est encore joint.",
      lead_decided_home:
        "La séance la plus récente d’abord. Les points avec un montant ou un vote partagé passent devant ; les formalités récurrentes en dernier.",
      lead_decided:
        "Résultats documentés dans les documents officiels, séance la plus récente d’abord, dans l’ordre de l’agenda.",
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
      back: "Terug",
      reset: "Zoekopdracht wissen",
      follow_communes: "Gemeentenieuws volgen",
      your_follows: "Uw gevolgde updates",
      explore: "Berichtgeving verkennen",
      none_mandates: "Geen geverifieerde openbare mandaten in deze selectie.",
      intro:
        "Volg openbare uitgaven, werken en stemmingen in vier Brusselse gemeenteraden, elk punt met het officiële document.",
      communes: "Gemeenten",
      follow: "Volgen",
      apply: "Bijwerken",
      search: "Zoeken",
      sections: "Onderdelen",
      today: "Vandaag gepland",
      coming: "Binnenkort",
      awaiting: "Uitkomst onbekend",
      none_awaiting: "Geen eerdere voorstellen zonder gedocumenteerde uitkomst in deze selectie.",
      filters: "Berichten filteren",
      previously: "Wat ze beslisten",
      unknown_heading: "Uitkomst nog niet gedocumenteerd",
      decided: "Wat ze beslisten",
      none_coming: "Geen komende berichtgeving.",
      none_decided: "Geen gedocumenteerde besluiten.",
      item: "Agendapunt",
      proposal: "Voorstel",
      outcome_unknown: "Uitkomst onbekend",
      decision: "Besluit",
      provenance: "Herkomst van de inhoud",
      mandates_pages: "Mandatenpagina's",
      previous_page: "Vorige pagina",
      next_page: "Volgende pagina",
      contested_votes: "Niet unaniem",
      contested_intro: "Besluiten met minstens één tegenstem of onthouding.",
      none_contested: "In deze selectie is geen verdeelde stemming gedocumenteerd.",
      contested_pages: "Pagina's met stemresultaten",
      commune: "Gemeente",
      meeting_date: "Datum van de zitting",
      votes_for: "Voor",
      votes_against: "Tegen",
      votes_abstentions: "Onthouding",
      all_communes_chip: "Alle gemeenten",
      latest_meetings: "Laatste vergaderingen",
      decided_count: "%{count} besluiten",
      tracking: "Tot nu toe %{meetings} vergaderingen en %{items} agendapunten gevolgd.",
      meetings: "Vergaderingen",
      lead_meetings: "Alle behandelde vergaderingen, de nieuwste eerst.",
      vote_split: "Stemverdeling",
      results: "%{count} punten",
      page: "Pagina",
      results_pages: "Resultaatpagina’s",
      all_communes: "de vier gemeenten",
      none_selected: "Kies minstens één gemeente om de berichtgeving te zien.",
      lead_coming: "Voorstellen op komende agenda’s. Hier is nog niets beslist.",
      lead_awaiting:
        "De vergadering heeft plaatsgevonden, maar er is nog geen officieel verslag van de uitkomst.",
      lead_decided_home:
        "Nieuwste vergadering eerst. Punten met een bedrag of verdeelde stemming staan vooraan; terugkerende formaliteiten als laatste.",
      lead_decided:
        "Uitkomsten uit officiële documenten, nieuwste vergadering eerst, in agendavolgorde.",
      source: "Bron"
    }
  end
end
