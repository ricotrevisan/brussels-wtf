defmodule BrusselsWtfWeb.MeetingPage do
  use BrusselsWtfWeb, :dstar_page

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.VoteTally

  @impl Dstar.Page
  def mount(conn, %{"commune" => commune, "municipal_id" => municipal_id} = params) do
    locale = BrusselsWtfWeb.Locale.resolve(conn, params)

    case Council.get_published_meeting_page(commune, municipal_id) do
      {:ok, page} ->
        variant = Enum.find(page.locale_variants, &(&1.locale == locale))
        locale_available = not is_nil(variant)
        withdrawn = page.publication_status == :draft and not is_nil(page.withdrawn_at)
        resource_path = BrusselsWtfWeb.PublicUrl.meeting_path(commune, municipal_id)

        tally_view =
          case params["votes"] do
            "all" -> :all
            "contested" -> :contested
            _ -> :default
          end

        assign(conn,
          page_title:
            cond do
              withdrawn -> text(locale, :withdrawn_title)
              locale_available -> variant.title
              true -> text(locale, :unavailable_title)
            end,
          html_lang: locale,
          resource_path: resource_path,
          noindex: withdrawn or not locale_available,
          meta_description:
            BrusselsWtfWeb.PublicDescription.meeting(
              locale,
              commune_name(locale, commune, page.council_meeting.commune.name),
              Date.to_iso8601(page.council_meeting.scheduled_on)
            ),
          meeting_page: page,
          variant: variant,
          locale_available: locale_available,
          withdrawn: withdrawn,
          withdrawal_reason: page.withdrawal_reasons[locale],
          corrections: correction_notes(page.publication_revisions, locale),
          historical_items:
            Enum.filter(
              page.council_meeting.agenda_items,
              &(not &1.published? and not is_nil(&1.published_item_number))
            ),
          revision_history: page.publication_revisions,
          locale: locale,
          tally_view: tally_view,
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
    <BrusselsWtfWeb.PublicShell.header
      locale={@locale}
      reader_back={true}
      current="/meetings"
      lang_href={fn code -> @resource_path <> "?lang=" <> code end}
    />

    <main id="content" class="site-container py-5 text-base-content sm:py-7" tabindex="-1">
      <a
        data-reader-back
        href={"/?lang=" <> @locale}
        class="inline-flex min-h-11 items-center gap-1.5 text-sm font-medium"
      >
        <span class="hero-arrow-left-micro size-4" aria-hidden="true"></span>{text(
          @locale,
          :back_to_results
        )}
      </a>
      <p :if={@withdrawn or not @locale_available} class="eyebrow mt-1">
        {@commune_name} ·
        <time datetime={Date.to_iso8601(@meeting_page.council_meeting.scheduled_on)}>
          {format_date(@meeting_page.council_meeting.scheduled_on, @locale)}
        </time>
      </p>
      <h1 class="display display-lg mt-1" data-meeting-title>
        <%= cond do %>
          <% @withdrawn -> %>
            {text(@locale, :withdrawn_title)}
          <% @locale_available -> %>
            {@commune_name} · {format_date(@meeting_page.council_meeting.scheduled_on, @locale)}
          <% true -> %>
            {text(@locale, :unavailable_title)}
        <% end %>
      </h1>
      <p :if={not @withdrawn and @locale_available} class="muted mt-1 text-sm">
        {@variant.title}
      </p>
      <p :if={not @withdrawn and not @locale_available} class="callout callout-unknown measure mt-5">
        {text(@locale, :unavailable_explanation)}
      </p>
      <div
        :if={not @withdrawn and @meeting_page.revision_published_at}
        class="mt-2 flex flex-wrap items-center gap-x-4 text-sm"
      >
        <a
          href={@meeting_page.citation_url}
          rel="external"
          class="inline-flex min-h-11 items-center gap-1.5 font-semibold"
        >
          <span class="hero-document-text-micro size-4" aria-hidden="true"></span>{text(
            @locale,
            :official_document
          )}
        </a>
      </div>

      <.meeting_stats :if={not @withdrawn and @items != []} items={@items} locale={@locale} />

      <details
        :if={not @withdrawn and @meeting_page.revision_published_at}
        class="disclosure mt-1"
        data-outcome-note
      >
        <summary>
          <span class="hero-information-circle-micro size-4" aria-hidden="true"></span>{text(
            @locale,
            :about_meeting
          )}
          <span class="chevron hero-chevron-down-micro" aria-hidden="true"></span>
        </summary>
        <div class="disclosure-body measure space-y-2 text-sm leading-6">
          <p>
            {text(@locale, :revision)}
            <time datetime={DateTime.to_iso8601(@meeting_page.revision_published_at)}>
              {format_datetime(@meeting_page.revision_published_at, @locale)}
            </time>
          </p>
          <p>{text(@locale, :agenda_note)}</p>
        </div>
      </details>

      <section :if={@withdrawn} class="callout callout-unknown mt-6">
        <h2 class="display display-md">{text(@locale, :withdrawn_heading)}</h2>
        <p class="mt-2 leading-6">{@withdrawal_reason || text(@locale, :withdrawn_explanation)}</p>
        <p :if={@meeting_page.withdrawn_at} class="muted mt-2 text-sm">
          {text(@locale, :withdrawn_on)}
          <time datetime={DateTime.to_iso8601(@meeting_page.withdrawn_at)}>
            {format_datetime(@meeting_page.withdrawn_at, @locale)}
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

      <section :if={not @withdrawn and @corrections != []} class="callout mt-5">
        <h2 class="font-semibold">{text(@locale, :corrections)}</h2>
        <ul class="mt-2 space-y-2 text-sm">
          <li :for={correction <- @corrections}>
            <time datetime={DateTime.to_iso8601(correction.published_at)}>
              {format_datetime(correction.published_at, @locale)}
            </time>
            · {correction.note}
          </li>
        </ul>
      </section>

      <details :if={not @withdrawn and @revision_history != []} class="disclosure mt-2 text-sm">
        <summary>
          <span class="chevron hero-chevron-down-micro" aria-hidden="true"></span>{text(
            @locale,
            :history
          )}
        </summary>
        <div class="disclosure-body measure">
          <p>{text(@locale, :historical_warning)}</p>
          <section
            :for={revision <- @revision_history}
            id={"revision-#{revision.id}"}
            tabindex="-1"
            class="mt-4 scroll-mt-4 border-t border-base-300 pt-3"
          >
            <h2 class="font-semibold">{format_datetime(revision.published_at, @locale)}</h2>
            <ul class="mt-2 space-y-2">
              <li :for={{_key, item} <- Enum.sort(revision.content["items"] || %{})}>
                <p>{get_in(item, ["variants", @locale, "title"])}</p>
                <p class="muted">{get_in(item, ["variants", @locale, "summary"])}</p>
              </li>
            </ul>
          </section>
        </div>
      </details>
      <.vote_tally
        :if={not @withdrawn}
        items={@items}
        locale={@locale}
        resource_path={@resource_path}
        view={@tally_view}
      />
      <section :if={not @withdrawn and @items != []} class="mt-7" aria-labelledby="agenda-heading">
        <div class="agenda-head flex flex-wrap items-end justify-between gap-x-4 gap-y-2 border-b-2 border-base-content pb-2">
          <h2 id="agenda-heading" class="display display-md">{text(@locale, :agenda)}</h2>
          <div class="agenda-tools hidden items-center gap-2" data-agenda-tools>
            <label class="flex min-w-0 items-center gap-2 text-sm">
              <span class="filter-label font-semibold">{text(@locale, :filter_label)}</span>
              <input
                type="search"
                data-agenda-filter
                placeholder={text(@locale, :filter_agenda)}
                class="input input-bordered input-sm min-h-11 w-44 sm:w-56"
              />
            </label>
            <button
              type="button"
              class="btn btn-ghost btn-sm min-h-11"
              data-expand-all
              data-expand-label={text(@locale, :expand_all)}
              data-collapse-label={text(@locale, :collapse_all)}
            >{text(@locale, :expand_all)}</button>
          </div>
        </div>
        <div class="topic-filters mt-2 hidden flex-wrap gap-1.5" data-topic-filters>
          <button
            :for={{topic, count} <- agenda_topics(@items)}
            type="button"
            class="topic-chip"
            data-topic-filter={topic}
          >
            <span class={[BrusselsWtfWeb.PublicShell.topic_icon(topic), "size-4"]} aria-hidden="true"></span>
            {BrusselsWtfWeb.PublicShell.topic_label(@locale, topic)}
            <span class="muted">{count}</span>
          </button>
        </div>
        <p class="mt-2 hidden items-center gap-3 text-sm font-semibold" data-agenda-result>
          <span role="status" data-agenda-count data-of={text(@locale, :of_items)}></span>
          <button type="button" class="btn btn-ghost btn-sm min-h-11" data-clear-filter>
            {text(@locale, :clear_filter)}
          </button>
        </p>
        <BrusselsWtfWeb.PublicShell.ai_key
          :if={Enum.any?(@items, &has_headline?(&1, @locale))}
          locale={@locale}
        />
        <p
          :if={all_unknown?(@items)}
          class="mt-2 flex flex-wrap items-center gap-2 text-sm"
          data-uniform-state
        >
          <BrusselsWtfWeb.PublicShell.status kind={:unknown} label={text(@locale, :outcome_unknown)} />
          <span class="muted">{text(@locale, :all_items)}</span>
        </p>
        <.coverage_item
          :for={item <- @items}
          item={item}
          page={@meeting_page}
          locale={@locale}
          uniform={all_unknown?(@items)}
        />
      </section>

      <section
        :if={not @withdrawn and @historical_items != []}
        class="callout callout-unknown mt-6"
      >
        <p>{text(@locale, :retired_item)}</p>
        <p :for={item <- @historical_items} id={item.stable_anchor} class="scroll-mt-4" tabindex="-1">
          {text(@locale, :item)} {item.published_item_number}: {text(@locale, :retired_item)}
        </p>
      </section>
    </main>
    <BrusselsWtfWeb.PublicationComponents.footer locale={@locale} />
    """
  end

  attr :items, :list, required: true
  attr :locale, :string, required: true

  defp meeting_stats(assigns) do
    decisions =
      assigns.items
      |> Enum.filter(&(display_state(&1) == :decision))

    assigns =
      assign(assigns,
        total: length(assigns.items),
        decided: length(decisions),
        awaiting: length(assigns.items) - length(decisions),
        contested:
          Enum.count(decisions, &(VoteTally.classify(&1.published_decision) == :contested))
      )

    ~H"""
    <div class="kpi-row mt-4" data-meeting-stats role="group" aria-label={text(@locale, :agenda)}>
      <.kpi value={@total} label={text(@locale, :stat_items)} filter="all" />
      <.kpi
        :if={@decided > 0}
        value={@decided}
        label={text(@locale, :stat_decided)}
        filter="decision"
        tone="tone-decided"
      />
      <.kpi
        value={@awaiting}
        label={text(@locale, :stat_awaiting)}
        filter="unknown"
        tone={@awaiting > 0 && "tone-unknown"}
      />
      <.kpi
        :if={@decided > 0}
        value={@contested}
        label={text(@locale, :stat_contested)}
        filter="contested"
      />
    </div>
    """
  end

  attr :value, :integer, required: true
  attr :label, :string, required: true
  attr :filter, :string, required: true
  attr :tone, :any, default: nil

  defp kpi(assigns) do
    ~H"""
    <a class="kpi" href="#agenda-heading" data-state-filter={@filter}>
      <span class={["kpi-value", @tone]}>{@value}</span>
      <span class="kpi-label">{@label}</span>
    </a>
    """
  end

  attr :items, :list, required: true
  attr :locale, :string, required: true
  attr :resource_path, :string, required: true
  attr :view, :atom, default: :default

  defp vote_tally(assigns) do
    rows =
      assigns.items
      |> Enum.filter(&(display_state(&1) == :decision))
      |> Enum.map(fn item ->
        decision = item.published_decision
        variant = Enum.find(item.coverage_variants, &(&1.locale == assigns.locale))

        %{
          anchor: item.stable_anchor,
          number: public_item_number(item),
          title: (variant && (variant.headline || variant.title)) || item.source_wording,
          ai_headline?: !!(variant && variant.headline),
          disposition: decision.disposition,
          for: decision.votes_for,
          against: decision.votes_against,
          abstentions: decision.abstentions,
          status: VoteTally.classify(decision)
        }
      end)

    stats = %{
      total: length(rows),
      unanimous: Enum.count(rows, &(&1.status == :unanimous)),
      contested: Enum.count(rows, &(&1.status == :contested)),
      not_recorded: Enum.count(rows, &(&1.status == :not_recorded))
    }

    visible =
      cond do
        assigns.view == :all ->
          rows

        assigns.view == :contested or stats.contested > 0 ->
          Enum.filter(rows, &(&1.status == :contested))

        true ->
          rows
      end

    assigns = assign(assigns, rows: rows, visible: visible, stats: stats)

    ~H"""
    <section
      :if={@stats.unanimous + @stats.contested > 0}
      id="vote-tally"
      aria-labelledby="vote-tally-heading"
      class="mt-5 scroll-mt-4"
      tabindex="-1"
    >
      <details class="disclosure border-y border-base-300" open={@view != :default}>
        <summary class="w-full justify-between py-1">
          <span>
            <span
              id="vote-tally-heading"
              class="block text-base font-semibold"
              role="heading"
              aria-level="2"
            >
              {text(@locale, :vote_tally)}
            </span>
            <span class="muted block text-sm font-normal" data-vote-stats>
              {tally_stats(@locale, @stats)}
            </span>
          </span>
          <span class="chevron hero-chevron-down-micro shrink-0" aria-hidden="true"></span>
        </summary>
        <div class="disclosure-body">
          <p class="flex flex-wrap items-center justify-between gap-x-4 text-sm">
            <BrusselsWtfWeb.PublicShell.vote_legend locale={@locale} />
            <a
              :if={@view == :all and @stats.contested > 0}
              href={@resource_path <> "?lang=" <> @locale <> "&votes=contested#vote-tally"}
              class="inline-flex min-h-11 items-center font-medium"
            >{text(@locale, :show_contested)}</a>
            <a
              :if={@view != :all and length(@visible) < length(@rows)}
              href={@resource_path <> "?lang=" <> @locale <> "&votes=all#vote-tally"}
              class="inline-flex min-h-11 items-center font-medium"
            >{text(@locale, :show_all_votes)}</a>
          </p>
          <p :if={@visible == []} class="mt-3 text-sm">{text(@locale, :no_contested_votes)}</p>
          <table :if={@visible != []} class="data-table mt-2">
            <thead>
              <tr>
                <th scope="col">#</th>
                <th scope="col">{text(@locale, :item)}</th>
                <th scope="col">{text(@locale, :decision)}</th>
                <th scope="col" class="num">{text(@locale, :votes_for)}</th>
                <th scope="col" class="num">{text(@locale, :votes_against)}</th>
                <th scope="col" class="num">{text(@locale, :votes_abstentions)}</th>
                <th scope="col"><span class="sr-only">{text(@locale, :vote_split)}</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @visible} data-vote-status={row.status}>
                <td data-label="#" class="tabular-nums">{row.number}</td>
                <td class="cell-lead">
                  <a href={"#" <> row.anchor} class="entry-title font-medium"><BrusselsWtfWeb.PublicShell.ai_mark
                    :if={row.ai_headline?}
                    locale={@locale}
                  />{row.title}</a>
                </td>
                <td data-label={text(@locale, :decision)}>
                  {String.capitalize(BrusselsWtfWeb.DispositionLabels.label(@locale, row.disposition))}
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
                <td class="cell-bar w-28">
                  <.vote_bar :if={row.status != :unanimous} row={row} locale={@locale} />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </details>
    </section>
    """
  end

  attr :row, :map, required: true
  attr :locale, :string, required: true

  defp vote_bar(assigns) do
    row = assigns.row
    total = (row.for || 0) + (row.against || 0) + (row.abstentions || 0)

    assigns =
      assign(assigns,
        total: total,
        segments:
          if(row.status == :not_recorded or total == 0,
            do: [],
            else:
              [
                {"bg-success", row.for},
                {"bg-error", row.against},
                {"bg-warning", row.abstentions}
              ]
              |> Enum.reject(fn {_class, value} -> (value || 0) == 0 end)
              |> Enum.map(fn {class, value} -> {class, Float.round(value * 100 / total, 2)} end)
          )
      )

    ~H"""
    <div
      :if={@segments != []}
      class="vote-bar mt-1"
      role="img"
      aria-label={vote_summary(@row, @locale)}
    >
      <span :for={{class, width} <- @segments} class={class} style={"width: #{width}%"}></span>
    </div>
    <span :if={@segments == []} class="muted">
      {text(@locale, :vote_not_recorded)}
    </span>
    """
  end

  defp count_cell(nil), do: "—"
  defp count_cell(value), do: value

  defp tally_stats(locale, stats) do
    base = text(locale, :tally_stats)

    base
    |> String.replace("%{total}", Integer.to_string(stats.total))
    |> String.replace("%{unanimous}", Integer.to_string(stats.unanimous))
    |> String.replace("%{contested}", Integer.to_string(stats.contested))
    |> then(fn copy ->
      if stats.not_recorded > 0,
        do:
          copy <>
            String.replace(
              text(locale, :tally_not_recorded),
              "%{count}",
              Integer.to_string(stats.not_recorded)
            ),
        else: copy
    end)
  end

  attr :item, :any, required: true
  attr :page, :any, required: true
  attr :locale, :string, required: true
  attr :uniform, :boolean, default: false

  defp coverage_item(assigns) do
    variant =
      Enum.find(assigns.item.coverage_variants, &(&1.locale == assigns.locale)) ||
        unavailable_coverage_variant(assigns.locale)

    assigns =
      assigns
      |> assign(:coverage_variant, variant)
      |> assign(
        :past,
        BrusselsWtfWeb.MeetingTime.past?(assigns.page.council_meeting.scheduled_on)
      )
      |> assign(:display_state, display_state(assigns.item))
      |> assign(:proposals, BrusselsWtfWeb.PublicEvidence.proposals(assigns.item))
      |> assign(:source_proposals, BrusselsWtfWeb.PublicEvidence.source_proposals(assigns.item))
      |> assign(:evidences, BrusselsWtfWeb.PublicEvidence.for_item(assigns.item))
      |> assign(:fact_paths, BrusselsWtf.Identity.PublicFactPaths.for_item(assigns.item))

    ~H"""
    <article
      id={@item.stable_anchor}
      class="agenda-item"
      tabindex="-1"
      data-state={if @display_state == :decision, do: "decision", else: "unknown"}
      data-contested={contested_item?(@item, @display_state) && "true"}
      data-agenda-item
      data-topic={
        BrusselsWtfWeb.PublicShell.topic_of(@item.source_wording || @coverage_variant.title)
      }
    >
      <details>
        <summary class="agenda-row">
          <span class="agenda-number">
            <span class="sr-only">{text(@locale, :item)}</span>
            {public_item_number(@item)}
          </span>
          <span class="min-w-0">
            <h2 class={["agenda-title", Map.get(@coverage_variant, :headline) && "has-headline"]}>
              <BrusselsWtfWeb.PublicShell.title_parts
                title={@coverage_variant.title}
                headline={Map.get(@coverage_variant, :headline)}
                locale={@locale}
              />
            </h2>
          </span>
          <span :if={not @uniform} class="agenda-meta">
            <span class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm">
              <BrusselsWtfWeb.PublicShell.status
                kind={row_status(@item, @display_state)}
                label={row_label(@item, @display_state, @locale)}
              />
              <BrusselsWtfWeb.PublicShell.vote_split
                :if={contested_item?(@item, @display_state)}
                for_votes={@item.published_decision.votes_for}
                against={@item.published_decision.votes_against}
                abstentions={@item.published_decision.abstentions}
                locale={@locale}
              />
              <span
                :if={@display_state == :decision and vote_summary(@item.published_decision, @locale)}
                class="muted"
              >
                {vote_summary(@item.published_decision, @locale)}
              </span>
            </span>
          </span>
          <span class="chevron agenda-chevron hero-chevron-down-micro" aria-hidden="true"></span>
        </summary>

        <div class="agenda-body">
          <div class="measure space-y-4">
            <div :if={@display_state == :decision} class="callout callout-decided">
              <h3 class="font-semibold">
                {text(@locale, :decision)}: {BrusselsWtfWeb.DispositionLabels.label(
                  @locale,
                  loaded_value(@item.published_decision, :disposition)
                )}
              </h3>
              <p class="mt-1 leading-6">
                {@coverage_variant.decision_summary || text(@locale, :decision_copy_unavailable)}
              </p>
            </div>

            <div :if={@proposals != []}>
              <h3 class="font-semibold">{text(@locale, :proposal)}</h3>
              <p class="mt-1 leading-6">
                {proposal_copy(@coverage_variant, @display_state, @locale, @past)}
              </p>
            </div>

            <div :if={@display_state in [:proposal, :unknown]} class="callout callout-unknown text-sm">
              <h3 class="font-semibold">{text(@locale, :outcome_unknown)}</h3>
              <p
                :if={@page.council_meeting.scheduled_on == BrusselsWtfWeb.MeetingTime.today()}
                class="mt-1"
              >
                {text(@locale, :today)}
              </p>
              <p :if={@past} class="mt-1">{text(@locale, :past_explanation)}</p>
              <p class="mt-1">{text(@locale, :unknown_explanation)}</p>
            </div>

            <details :if={@source_proposals != []} class="disclosure">
              <summary>
                <span class="chevron hero-chevron-down-micro" aria-hidden="true"></span>{text(
                  @locale,
                  :proposal_interpretation
                )}
              </summary>
              <div class="disclosure-body">
                <p :for={proposal <- @source_proposals} lang="und" class="text-sm leading-6">
                  {proposal.text}
                </p>
              </div>
            </details>

            <div :if={@item.dossier_links != []} class="text-sm">
              <h3 class="font-semibold">{text(@locale, :dossiers)}</h3>
              <ul class="mt-1">
                <li :for={link <- @item.dossier_links}>
                  <a
                    href={"/dossiers/#{link.dossier.slug}?lang=#{@locale}"}
                    class="inline-flex min-h-11 items-center gap-1.5"
                  >
                    <span class="hero-folder-open-micro size-4" aria-hidden="true"></span>
                    {Map.get(link.dossier.localized_titles || %{}, @locale, link.dossier.title)}
                  </a>
                </li>
              </ul>
            </div>

            <section aria-label={text(@locale, :evidence)}>
              <h3 class="font-semibold">{text(@locale, :evidence)}</h3>
              <ul :if={@evidences != []} class="mt-1 text-sm">
                <li :for={evidence <- @evidences}>
                  <a
                    href={BrusselsWtfWeb.PublicEvidence.citation_href(evidence)}
                    rel="external"
                    class="inline-flex min-h-11 items-center gap-1.5 py-1"
                  >
                    <span class="hero-document-text-micro size-4 shrink-0" aria-hidden="true"></span>
                    <span>{evidence_title(evidence, @locale)}</span>
                  </a>
                  <span :if={evidence.synthetic} class="tone-unknown block font-medium">
                    {text(@locale, :synthetic_reference)}
                  </span>
                  <details :if={not evidence.synthetic} class="disclosure">
                    <summary class="muted font-normal">
                      <span class="chevron hero-chevron-down-micro" aria-hidden="true"></span>{text(
                        @locale,
                        :source_details
                      )}
                    </summary>
                    <div class="disclosure-body muted">
                      {text(@locale, :retrieved)}
                      <time datetime={DateTime.to_iso8601(evidence.retrieved_at)}>
                        {format_datetime(evidence.retrieved_at, @locale)}
                      </time>
                      <span :if={evidence.checksum} class="block">
                        SHA-256 <code class="break-all">{evidence.checksum}</code>
                      </span>
                    </div>
                  </details>
                </li>
              </ul>
              <p :if={@evidences == []} class="mt-1 text-sm">
                <a
                  href={@page.citation_url}
                  rel="external"
                  class="inline-flex min-h-11 items-center gap-1.5"
                >
                  <span class="hero-document-text-micro size-4" aria-hidden="true"></span>
                  {text(@locale, :source)}
                </a>
              </p>
            </section>

            <p
              :if={@coverage_variant.provenance != []}
              class="muted flex flex-wrap items-center gap-x-3 gap-y-1 text-sm"
              aria-label={text(@locale, :provenance)}
            >
              <span
                :for={{icon, label} <- provenance_labels(@coverage_variant.provenance, @locale)}
                class="inline-flex items-center gap-1"
              >
                <span class={[icon, "size-4"]} aria-hidden="true"></span>{label}
              </span>
            </p>

            <section :if={@fact_paths != []} aria-labelledby={"fact-paths-" <> @item.stable_anchor}>
              <h3 id={"fact-paths-" <> @item.stable_anchor} class="font-semibold">
                {text(@locale, :fact_paths)}
              </h3>
              <ol class="mt-3 space-y-4">
                <li :for={path <- @fact_paths} class="border-l-2 border-base-300 pl-4">
                  <ol class="space-y-3">
                    <li :for={edge <- path.edges}>
                      <p class="font-semibold">{Map.fetch!(edge.labels, @locale)}</p>
                      <p class="mt-1">{edge.subject_name} — {edge.object_name}</p>
                      <p :if={edge.effective_from} class="muted mt-1 text-sm">
                        <time datetime={Date.to_iso8601(edge.effective_from)}>
                          {format_date(edge.effective_from, @locale)}
                        </time>
                      </p>
                      <p class="mt-1 text-sm">
                        <a
                          href={edge.citation_url}
                          rel="external"
                          class="inline-flex min-h-11 items-center"
                        >
                          {text(@locale, :source)}
                        </a>
                      </p>
                    </li>
                  </ol>
                </li>
              </ol>
            </section>
            <BrusselsWtfWeb.PublicationComponents.correction_form locale={@locale} item_id={@item.id} />
          </div>
        </div>
      </details>
    </article>
    """
  end

  defp agenda_topics(items) do
    items
    |> Enum.map(&BrusselsWtfWeb.PublicShell.topic_of(&1.source_wording))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_topic, count} -> -count end)
  end

  defp has_headline?(item, locale) do
    Enum.any?(item.coverage_variants, &(&1.locale == locale and &1.headline))
  end

  defp all_unknown?(items), do: Enum.all?(items, &(display_state(&1) != :decision))

  defp contested_item?(item, :decision),
    do: VoteTally.classify(item.published_decision) == :contested

  defp contested_item?(_item, _state), do: false

  defp row_status(_item, state) when state in [:proposal, :unknown], do: :unknown

  defp row_status(item, _state),
    do: loaded_value(item.published_decision, :disposition) || :decided

  defp row_label(_item, state, locale) when state in [:proposal, :unknown],
    do: text(locale, :outcome_unknown)

  defp row_label(item, _state, locale),
    do:
      String.capitalize(
        BrusselsWtfWeb.DispositionLabels.label(
          locale,
          loaded_value(item.published_decision, :disposition)
        )
      )

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

  defp proposal_copy(variant, :decision, locale, _past),
    do: variant.proposal_summary || text(locale, :proposal_copy_unavailable)

  defp proposal_copy(variant, _state, locale, past) do
    copy = variant.proposal_summary || variant.summary

    if past and
         Enum.any?(
           [
             "has yet to consider",
             "is due to consider",
             "doit encore",
             "doit examiner",
             "moet de",
             "moet dit"
           ],
           &String.contains?(copy || "", &1)
         ),
       do: text(locale, :past_proposal),
       else: copy
  end

  defp evidence_title(evidence, locale) do
    case evidence.source_title do
      "Authoritative municipal source" ->
        evidence.location || text(locale, :source)

      title ->
        title
    end
  end

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

  defp vote_summary(%{for: for_votes, against: against, abstentions: abstentions}, locale),
    do:
      vote_summary(
        %{votes_for: for_votes, votes_against: against, abstentions: abstentions},
        locale
      )

  defp vote_summary(decision, locale),
    do:
      BrusselsWtfWeb.PublicShell.vote_text(
        locale,
        decision.votes_for,
        decision.votes_against,
        decision.abstentions
      )

  defp provenance_labels(values, locale) do
    labels = %{
      "en" => %{
        ai_generated: "AI-generated",
        machine_translated: "Machine-translated",
        human_reviewed: "Human-reviewed"
      },
      "fr" => %{
        ai_generated: "Généré par IA",
        machine_translated: "Traduction automatique",
        human_reviewed: "Révisé par une personne"
      },
      "nl" => %{
        ai_generated: "AI-gegenereerd",
        machine_translated: "Machinevertaling",
        human_reviewed: "Door een mens nagekeken"
      }
    }

    Enum.map(values, &{provenance_icon(&1), labels[locale][&1]})
  end

  defp provenance_icon(:ai_generated), do: "hero-sparkles-micro"
  defp provenance_icon(:machine_translated), do: "hero-language-micro"
  defp provenance_icon(_value), do: "hero-user-micro"

  defp commune_name("fr", "city-of-brussels", _name), do: "Ville de Bruxelles"
  defp commune_name("nl", "city-of-brussels", _name), do: "Stad Brussel"
  defp commune_name("nl", "ixelles", _name), do: "Elsene"
  defp commune_name("nl", "uccle", _name), do: "Ukkel"
  defp commune_name("nl", "forest", _name), do: "Vorst"
  defp commune_name(_locale, _slug, name), do: name

  defp format_date(date, locale), do: BrusselsWtfWeb.PublicDate.long(date, locale)

  defp format_datetime(datetime, locale),
    do: BrusselsWtfWeb.PublicDate.long_datetime(datetime, locale)

  defp text("fr", key), do: Map.fetch!(fr_text(), key)
  defp text("nl", key), do: Map.fetch!(nl_text(), key)
  defp text(_locale, key), do: Map.fetch!(en_text(), key)

  defp en_text do
    %{
      skip: "Skip to content",
      past_explanation:
        "The meeting date has passed. Its final outcome is not yet documented here.",
      fact_paths: "Fact paths",
      today: "Scheduled today",
      past_proposal:
        "The agenda records this proposal. No authoritative final outcome is attached.",
      proposal_interpretation: "Source-backed proposal interpretation",
      source_details: "Verification details",
      unavailable_title: "Coverage unavailable in English",
      item_unavailable: "Agenda-item coverage unavailable in English",
      unavailable_explanation:
        "This meeting has no complete English coverage. No text from another language is substituted.",
      decision_copy_unavailable: "Decision copy is unavailable in English.",
      proposal_copy_unavailable: "Proposal copy is unavailable in English.",
      synthetic_reference: "Demonstration reference — not evidence of council activity",
      retired_item:
        "This earlier item reference was replaced or removed after source verification. Consult the current selection and dated history above.",
      history: "Dated publication history",
      historical_warning:
        "Earlier wording is retained for transparency and may contain errors corrected in the current version.",
      back_to_results: "Back",
      revision: "Updated",
      item: "Agenda item",
      proposal: "Proposal",
      outcome_unknown: "Outcome unknown",
      unknown_explanation: "No authoritative final record is attached to this item.",
      decision: "Decision",
      provenance: "Content provenance",
      dossiers: "Continuing dossier",
      evidence: "Sources",
      source: "Official source",
      retrieved: "Retrieved",
      withdrawn_title: "Meeting coverage withdrawn",
      withdrawn_heading: "This coverage has been withdrawn",
      withdrawn_explanation: "The page is temporarily unavailable while its content is reviewed.",
      withdrawn_on: "Withdrawn:",
      item_withdrawn: "Coverage for this agenda item is temporarily unavailable.",
      corrections: "Corrections",
      official_document: "Official document",
      agenda: "Agenda",
      all_items: "applies to every item below.",
      about_meeting: "About this meeting",
      agenda_note:
        "An item stays Outcome unknown until an official record of its outcome is attached. Only items the council votes on are published, so numbers can skip.",
      filter_agenda: "Filter this agenda",
      of_items: "%{shown} of %{total} items",
      clear_filter: "Clear filter",
      filter_label: "Filter",
      expand_all: "Open all",
      collapse_all: "Close all",
      stat_items: "Items",
      stat_decided: "Decisions",
      stat_awaiting: "Outcome unknown",
      stat_contested: "Not unanimous",
      vote_tally: "Vote tally",
      tally_stats: "Decisions: %{total} · unanimous: %{unanimous} · not unanimous: %{contested}",
      tally_not_recorded: " · no recorded tally: %{count}",
      show_contested: "Show votes that were not unanimous",
      show_all_votes: "Show all decisions",
      no_contested_votes: "Every recorded vote at this meeting was unanimous.",
      votes_for: "For",
      votes_against: "Against",
      votes_abstentions: "Abstained",
      vote_split: "Vote split",
      vote_not_recorded: "Not recorded"
    }
  end

  defp fr_text do
    %{
      skip: "Aller au contenu",
      past_explanation:
        "La date de la réunion est passée. Son résultat final n’est pas encore documenté ici.",
      fact_paths: "Chemins de faits",
      today: "Prévu aujourd’hui",
      past_proposal:
        "L’ordre du jour présente cette proposition. Aucun résultat final officiel n’est joint.",
      proposal_interpretation: "Interprétation de la proposition fondée sur les sources",
      source_details: "Détails de vérification",
      unavailable_title: "Contenu indisponible en français",
      item_unavailable: "Contenu du point indisponible en français",
      unavailable_explanation:
        "Cette réunion ne dispose pas d’une version française complète. Aucun texte d’une autre langue n’est substitué.",
      decision_copy_unavailable: "Le texte de la décision n’est pas disponible en français.",
      proposal_copy_unavailable: "Le texte de la proposition n’est pas disponible en français.",
      synthetic_reference:
        "Référence de démonstration — ne constitue pas une preuve d’activité communale",
      retired_item:
        "Cette ancienne référence a été remplacée ou retirée après vérification des sources. Consultez la sélection actuelle et l’historique daté ci-dessus.",
      history: "Historique daté des publications",
      historical_warning:
        "Les anciens textes sont conservés par transparence et peuvent contenir des erreurs corrigées dans la version actuelle.",
      back_to_results: "Retour",
      revision: "Mis à jour le",
      item: "Point",
      proposal: "Proposition",
      outcome_unknown: "Résultat inconnu",
      unknown_explanation: "Aucun document final officiel n’est joint à ce point.",
      decision: "Décision",
      provenance: "Provenance du contenu",
      dossiers: "Dossier en cours",
      evidence: "Sources",
      source: "Source officielle",
      retrieved: "Récupérée",
      withdrawn_title: "Contenu de la réunion retiré",
      withdrawn_heading: "Ce contenu a été retiré",
      withdrawn_explanation:
        "La page est temporairement indisponible pendant la vérification de son contenu.",
      withdrawn_on: "Retiré le :",
      item_withdrawn: "Le contenu de ce point est temporairement indisponible.",
      corrections: "Corrections",
      official_document: "Document officiel",
      agenda: "Ordre du jour",
      all_items: "vaut pour tous les points ci-dessous.",
      about_meeting: "À propos de cette séance",
      agenda_note:
        "Un point reste en Résultat inconnu tant qu’aucun document officiel de son résultat n’est joint. Seuls les points soumis au vote sont publiés, la numérotation peut donc sauter.",
      filter_agenda: "Filtrer cet ordre du jour",
      of_items: "%{shown} points sur %{total}",
      clear_filter: "Effacer le filtre",
      filter_label: "Filtrer",
      expand_all: "Tout ouvrir",
      collapse_all: "Tout fermer",
      stat_items: "Points",
      stat_decided: "Décisions",
      stat_awaiting: "Résultat inconnu",
      stat_contested: "Pas unanimes",
      vote_tally: "Résultats des votes",
      tally_stats: "Décisions : %{total} · unanimes : %{unanimous} · non unanimes : %{contested}",
      tally_not_recorded: " · sans décompte documenté : %{count}",
      show_contested: "Afficher les votes non unanimes",
      show_all_votes: "Afficher toutes les décisions",
      no_contested_votes: "Tous les votes documentés de cette réunion sont unanimes.",
      votes_for: "Pour",
      votes_against: "Contre",
      votes_abstentions: "Abstention",
      vote_split: "Répartition des votes",
      vote_not_recorded: "Non documenté"
    }
  end

  defp nl_text do
    %{
      skip: "Naar inhoud",
      past_explanation:
        "De vergaderdatum is verstreken. De definitieve uitkomst is hier nog niet gedocumenteerd.",
      fact_paths: "Feitenpaden",
      today: "Vandaag gepland",
      past_proposal:
        "De agenda vermeldt dit voorstel. Er is geen officiële definitieve uitkomst toegevoegd.",
      proposal_interpretation: "Brononderbouwde interpretatie van het voorstel",
      source_details: "Verificatiedetails",
      unavailable_title: "Inhoud niet beschikbaar in het Nederlands",
      item_unavailable: "Inhoud van het agendapunt niet beschikbaar in het Nederlands",
      unavailable_explanation:
        "Voor deze vergadering is geen volledige Nederlandse versie beschikbaar. Tekst uit een andere taal wordt niet ingevoegd.",
      decision_copy_unavailable: "De beslissingstekst is niet beschikbaar in het Nederlands.",
      proposal_copy_unavailable: "De voorsteltekst is niet beschikbaar in het Nederlands.",
      synthetic_reference: "Demonstratiereferentie — geen bewijs van gemeentelijke activiteit",
      retired_item:
        "Deze eerdere verwijzing is na broncontrole vervangen of verwijderd. Bekijk de huidige selectie en de gedateerde geschiedenis hierboven.",
      history: "Gedateerde publicatiegeschiedenis",
      historical_warning:
        "Eerdere teksten worden voor transparantie bewaard en kunnen fouten bevatten die in de huidige versie zijn gecorrigeerd.",
      back_to_results: "Terug",
      revision: "Bijgewerkt op",
      item: "Agendapunt",
      proposal: "Voorstel",
      outcome_unknown: "Uitkomst onbekend",
      unknown_explanation: "Aan dit punt is geen officieel eindverslag gekoppeld.",
      decision: "Besluit",
      provenance: "Herkomst van de inhoud",
      dossiers: "Lopend dossier",
      evidence: "Bronnen",
      source: "Officiële bron",
      retrieved: "Opgehaald",
      withdrawn_title: "Vergaderbericht ingetrokken",
      withdrawn_heading: "Dit bericht is ingetrokken",
      withdrawn_explanation:
        "De pagina is tijdelijk niet beschikbaar terwijl de inhoud wordt nagekeken.",
      withdrawn_on: "Ingetrokken op:",
      item_withdrawn: "Het bericht over dit agendapunt is tijdelijk niet beschikbaar.",
      corrections: "Correcties",
      official_document: "Officieel document",
      agenda: "Agenda",
      all_items: "geldt voor alle punten hieronder.",
      about_meeting: "Over deze vergadering",
      agenda_note:
        "Een punt blijft op Uitkomst onbekend staan tot een officieel document van de uitkomst is toegevoegd. Alleen punten waarover de raad stemt worden gepubliceerd, dus nummers kunnen ontbreken.",
      filter_agenda: "Deze agenda filteren",
      of_items: "%{shown} van %{total} punten",
      clear_filter: "Filter wissen",
      filter_label: "Filter",
      expand_all: "Alles openen",
      collapse_all: "Alles sluiten",
      stat_items: "Punten",
      stat_decided: "Besluiten",
      stat_awaiting: "Uitkomst onbekend",
      stat_contested: "Niet unaniem",
      vote_tally: "Stemmingsresultaten",
      tally_stats: "Besluiten: %{total} · unaniem: %{unanimous} · niet unaniem: %{contested}",
      tally_not_recorded: " · zonder gedocumenteerde stemming: %{count}",
      show_contested: "Niet-unanieme stemmingen tonen",
      show_all_votes: "Alle besluiten tonen",
      no_contested_votes: "Alle gedocumenteerde stemmingen van deze vergadering waren unaniem.",
      votes_for: "Voor",
      votes_against: "Tegen",
      votes_abstentions: "Onthouding",
      vote_split: "Stemverdeling",
      vote_not_recorded: "Niet gedocumenteerd"
    }
  end
end
