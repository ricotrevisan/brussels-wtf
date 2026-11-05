defmodule BrusselsWtfWeb.PublicShell do
  @moduledoc "The header, navigation and status vocabulary shared by every public page."
  use Phoenix.Component

  alias BrusselsWtfWeb.Layouts

  attr :locale, :string, required: true
  attr :lang_href, :any, required: true, doc: "one-argument function from language code to URL"
  attr :home_href, :string, default: nil
  attr :current, :string, default: nil, doc: "path of the current section"
  attr :selection, :string, default: "", doc: "commune query kept when moving between lists"
  attr :reader_back, :boolean, default: false

  def header(assigns) do
    ~H"""
    <a href="#content" class="skip-link">{copy(@locale, :skip)}</a>
    <header class="site-header">
      <div class="site-container">
        <div class="flex items-center justify-between gap-3 py-2.5">
          <Layouts.brand_link
            href={@home_href || "/?lang=" <> @locale}
            data-reader-back={@reader_back && "true"}
          />
          <nav aria-label={copy(@locale, :language)}>
            <ul class="lang-switch">
              <li :for={{code, label} <- [{"fr", "FR"}, {"nl", "NL"}, {"en", "EN"}]}>
                <a
                  href={@lang_href.(code)}
                  lang={code}
                  hreflang={code}
                  aria-current={if code == @locale, do: "page"}
                >{label}</a>
              </li>
            </ul>
          </nav>
        </div>
        <nav aria-label={copy(@locale, :sections)} class="site-nav" data-site-nav>
          <a
            :for={{path, key} <- sections()}
            href={section_href(path, @locale, @selection)}
            aria-current={if path == @current, do: "page"}
          >{copy(@locale, key)}</a>
        </nav>
        <details class="site-menu">
          <summary>
            <span class="hero-bars-3-micro size-4" aria-hidden="true"></span>
            <span>{copy(@locale, :menu)}</span>
            <span :if={current_label(@current, @locale)} class="muted min-w-0 truncate font-normal">
              · {current_label(@current, @locale)}
            </span>
            <span class="chevron hero-chevron-down-micro ml-auto" aria-hidden="true"></span>
          </summary>
          <nav aria-label={copy(@locale, :sections)} class="pb-2">
            <a
              :for={{path, key} <- sections()}
              href={section_href(path, @locale, @selection)}
              aria-current={if path == @current, do: "page"}
            >{copy(@locale, key)}</a>
          </nav>
        </details>
      </div>
    </header>
    """
  end

  attr :kind, :atom, required: true
  attr :label, :string, required: true

  def status(assigns) do
    ~H"""
    <span class={["state-pill", "state-pill-" <> tone(@kind)]} data-status={@kind}>
      <span class={[icon(@kind) <> "-micro", "size-4 shrink-0"]} aria-hidden="true"></span>
      {@label}
    </span>
    """
  end

  attr :for_votes, :any, required: true
  attr :against, :any, required: true
  attr :abstentions, :any, required: true
  attr :locale, :string, required: true
  attr :label, :boolean, default: true

  @doc "A proportional bar for a split vote. Its counts are always printed next to it."
  def vote_split(assigns) do
    total = (assigns.for_votes || 0) + (assigns.against || 0) + (assigns.abstentions || 0)

    percent = fn value ->
      if total > 0, do: Float.round((value || 0) * 100 / total, 2), else: 0
    end

    assigns =
      assign(assigns,
        segments:
          [
            {"bg-success", percent.(assigns.for_votes)},
            {"bg-error", percent.(assigns.against)},
            {"bg-warning", percent.(assigns.abstentions)}
          ]
          |> Enum.reject(fn {_class, width} -> width == 0 end)
      )

    ~H"""
    <span class={[@label && "state-pill state-pill-neutral"]} data-contested-mark>
      <span class="mini-bar" aria-hidden="true">
        <span :for={{class, width} <- @segments} class={class} style={"width: #{width}%"}></span>
      </span>
      <span :if={@label}>{copy(@locale, :contested_one)}</span>
    </span>
    """
  end

  attr :locale, :string, required: true

  def vote_legend(assigns) do
    ~H"""
    <p class="legend" data-vote-legend>
      <span><i class="bg-success"></i>{copy(@locale, :votes_for)}</span>
      <span><i class="bg-error"></i>{copy(@locale, :votes_against)}</span>
      <span><i class="bg-warning"></i>{copy(@locale, :votes_abstained)}</span>
    </p>
    """
  end

  @doc "Renders the shared shell around server-built private pages such as the feed."
  def document(opts) do
    locale = Keyword.fetch!(opts, :locale)
    path = Keyword.fetch!(opts, :path)
    title = Keyword.fetch!(opts, :title)

    header =
      %{
        __changed__: nil,
        locale: locale,
        current: Keyword.get(opts, :current),
        selection: "",
        home_href: nil,
        reader_back: false,
        lang_href: &(path <> "?lang=" <> &1)
      }
      |> header()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    footer =
      %{__changed__: nil, locale: locale}
      |> BrusselsWtfWeb.PublicationComponents.footer()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    """
    <!doctype html><html lang="#{locale}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">#{Keyword.get(opts, :head, "")}<title>#{title}</title><link rel="stylesheet" href="#{BrusselsWtfWeb.Endpoint.static_path("/assets/css/app.css")}"></head><body>#{header}<main id="content" tabindex="-1" class="site-container plain-page py-8"><h1 class="display display-lg">#{title}</h1>#{Keyword.fetch!(opts, :body)}</main>#{footer}</body></html>
    """
  end

  def section_href("/", locale, ""), do: "/?lang=" <> locale

  def section_href(path, locale, selection) when path in ["/about", "/feed"],
    do: section_href_plain(path, locale, selection)

  def section_href(path, locale, ""), do: path <> "?lang=" <> locale
  def section_href(path, locale, selection), do: path <> "?lang=" <> locale <> "&" <> selection

  defp section_href_plain(path, locale, _selection), do: path <> "?lang=" <> locale

  defp current_label(current, locale) do
    case List.keyfind(sections(), current, 0) do
      {_path, key} -> copy(locale, key)
      nil -> nil
    end
  end

  @doc "One wording for vote counts on every page."
  def vote_text(locale, for_votes, against, abstentions) do
    if is_nil(for_votes) and is_nil(against) and is_nil(abstentions) do
      nil
    else
      [
        vote_part(locale, :for, for_votes),
        vote_part(locale, :against, against),
        vote_part(locale, :abstentions, abstentions)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")
    end
  end

  defp vote_part(_locale, _kind, nil), do: nil
  defp vote_part("fr", :for, value), do: "#{value} pour"
  defp vote_part("fr", :against, value), do: "#{value} contre"
  defp vote_part("fr", :abstentions, value) when value > 1, do: "#{value} abstentions"
  defp vote_part("fr", :abstentions, value), do: "#{value} abstention"
  defp vote_part("nl", :for, value), do: "#{value} voor"
  defp vote_part("nl", :against, value), do: "#{value} tegen"
  defp vote_part("nl", :abstentions, 1), do: "1 onthouding"
  defp vote_part("nl", :abstentions, value), do: "#{value} onthoudingen"
  defp vote_part(_locale, :for, value), do: "#{value} for"
  defp vote_part(_locale, :against, value), do: "#{value} against"
  defp vote_part(_locale, :abstentions, value), do: "#{value} abstained"

  attr :title, :string, required: true

  @doc "Keeps the official wording whole: its first sentence leads, the rest stays quieter."
  def title_parts(assigns) do
    {lead, rest} = split_title(assigns.title)
    assigns = assign(assigns, lead: lead, rest: rest)

    ~H"""
    <span class="title-lead">{@lead}</span>{" "}<span :if={@rest} class="title-rest">{@rest}</span>
    """
  end

  def split_title(title) when is_binary(title) do
    case Regex.run(
           ~r/^(.{25,}?(?<!\bMs|\bMr|\bMme|\bDr|\bno|\bnr|\bart|\bincl|\bexcl|\bavec|\bvs)(?<=[\p{Ll}\d)»"”]))\.\s+(\p{Lu}.*)$/su,
           title
         ) do
      [_, lead, _rest] when byte_size(lead) > 110 -> split_at_clause(title)
      [_, lead, rest] -> {lead <> ".", rest}
      _ -> split_at_clause(title)
    end
  end

  def split_title(title), do: {title, nil}

  # A long title with no sentence break still gets a shorter lead, at its first clause.
  defp split_at_clause(title) do
    with true <- String.length(title) > 90,
         [_, lead, rest] <- Regex.run(~r/^(.{40,}?[,;:–])\s+(.+)$/su, title) do
      {lead, rest}
    else
      _ -> {title, nil}
    end
  end

  attr :topic, :any, required: true
  attr :amount, :string, default: nil
  attr :locale, :string, required: true

  @doc "A rule-based topic from fixed keywords, plus any amount quoted in the title."
  def kicker(assigns) do
    ~H"""
    <p class="kicker" data-kicker>
      <span class={[topic_icon(@topic), "size-4"]} aria-hidden="true"></span>
      <span>{copy(@locale, @topic)}</span>
      <span :if={@amount} aria-hidden="true">·</span>
      <span :if={@amount} data-amount>{@amount}</span>
    </p>
    """
  end

  # First match wins. Keywords cover the official wording in French, Dutch and English;
  # a title that matches nothing falls back to the general label.
  @topics [
    {:topic_subsidy, ~r/\b(subsid|subvention|toelage)/iu},
    {:topic_settlement, ~r/\b(settlement|transaction|dading|vaststellingsovereenkomst)/iu},
    {:topic_works,
     ~r/\b(travaux|works?\b|werken\b|aménagement|renovation|rénovation|renovatie)/iu},
    {:topic_money, ~r/\b(budget|compte de l|financial year|jaarrekening|taxe|tax\b|belasting)/iu},
    {:topic_property, ~r/\b(occupation|occupancy|bail\b|lease|huur|immeuble|acquisition)/iu},
    {:topic_staff, ~r/\b(personnel|staff|personeel|règlement de travail|arbeidsreglement)/iu}
  ]

  def topic_of(title) when is_binary(title) do
    case Enum.find(@topics, fn {_topic, pattern} -> Regex.match?(pattern, title) end) do
      {topic, _pattern} -> topic
      nil -> :topic_general
    end
  end

  def topic_of(_title), do: :topic_general

  def topic_label(locale, topic), do: copy(locale, topic)

  def topic_icon(:topic_subsidy), do: "hero-banknotes-micro"
  def topic_icon(:topic_settlement), do: "hero-document-check-micro"
  def topic_icon(:topic_works), do: "hero-wrench-screwdriver-micro"
  def topic_icon(:topic_money), do: "hero-calculator-micro"
  def topic_icon(:topic_property), do: "hero-building-office-micro"
  def topic_icon(:topic_staff), do: "hero-users-micro"
  def topic_icon(_topic), do: "hero-building-library-micro"

  @doc "Empty state for the follows page; CSS hides it once the list has rows."
  def feed_empty(locale) do
    href = "/coverage/decisions?lang=" <> locale

    ~s(<p class="callout feed-empty" data-feed-empty>#{copy(locale, :feed_empty)} <a href="#{href}" class="inline-flex min-h-11 items-center font-semibold underline">#{copy(locale, :feed_cta)}</a></p>)
  end

  @doc "The first amount quoted in a title, written the same way for every row in a language."
  def amount_in(title, locale \\ "en")

  def amount_in(title, locale) when is_binary(title) do
    case Regex.run(~r/(?:EUR|€)\s?(\d[\d .,]*\d)|(\d[\d .,]*\d)\s?(?:EUR|€|euros?)/iu, title) do
      [_, digits] -> format_amount(digits, locale)
      [_, "", digits] -> format_amount(digits, locale)
      _ -> nil
    end
  end

  def amount_in(_title, _locale), do: nil

  defp format_amount(raw, locale) do
    compact = String.replace(raw, " ", "")

    {whole, cents} =
      case Regex.run(~r/^(.*)[.,](\d{2})$/, compact) do
        [_, whole, cents] -> {whole, cents}
        _ -> {compact, "00"}
      end

    whole = String.replace(whole, ~r/[.,]/, "")

    grouped =
      whole
      |> String.to_charlist()
      |> Enum.reverse()
      |> Enum.chunk_every(3)
      |> Enum.map(&Enum.reverse/1)
      |> Enum.reverse()
      |> Enum.join(separator(:group, locale))

    shown = if cents == "00", do: grouped, else: grouped <> separator(:decimal, locale) <> cents

    case locale do
      "fr" -> shown <> " €"
      "nl" -> "€ " <> shown
      _ -> "€" <> shown
    end
  end

  defp separator(:group, "fr"), do: " "
  defp separator(:group, "nl"), do: "."
  defp separator(:group, _locale), do: ","
  defp separator(:decimal, "en"), do: "."
  defp separator(:decimal, _locale), do: ","

  defp sections do
    [
      {"/meetings", :meetings},
      {"/coverage/coming-up", :coming},
      {"/coverage/decisions", :decisions},
      {"/coverage/contested-votes", :contested},
      {"/coverage/awaiting-outcome", :awaiting},
      {"/mandates", :mandates},
      {"/feed", :follows},
      {"/about", :about}
    ]
  end

  defp tone(kind) when kind in [:coming, :proposal], do: "coming"
  defp tone(kind) when kind in [:unknown, :awaiting], do: "unknown"
  defp tone(:rejected), do: "contested"
  defp tone(kind) when kind in [:decided, :decision, :approved, :amended], do: "decided"
  defp tone(_kind), do: "neutral"

  def icon(kind) when kind in [:coming, :proposal], do: "hero-calendar-days"
  def icon(kind) when kind in [:unknown, :awaiting], do: "hero-clock"
  def icon(:rejected), do: "hero-x-circle"
  def icon(:postponed), do: "hero-pause-circle"
  def icon(:withdrawn), do: "hero-minus-circle"
  def icon(_kind), do: "hero-check-circle"

  defp copy(locale, key), do: Map.fetch!(Map.get(text(), locale, text()["en"]), key)

  defp text do
    %{
      "en" => %{
        skip: "Skip to content",
        language: "Language",
        sections: "Sections",
        decisions: "Decisions",
        coming: "Coming up",
        awaiting: "Outcome unknown",
        menu: "Menu",
        topic_general: "Council business",
        topic_subsidy: "Subsidy",
        topic_settlement: "Settlement",
        topic_works: "Public works",
        topic_money: "Public money",
        topic_property: "Property",
        topic_staff: "Staff",
        contested_one: "Not unanimous",
        feed_empty:
          "You aren’t following anything yet. Open a list and choose which commune or dossier to follow.",
        feed_cta: "Browse decisions",
        contested: "Not unanimous",
        mandates: "Public mandates",
        meetings: "Meetings",
        follows: "Personal feed",
        about: "About",
        votes_for: "For",
        votes_against: "Against",
        votes_abstained: "Abstained"
      },
      "fr" => %{
        skip: "Aller au contenu",
        language: "Langue",
        sections: "Rubriques",
        decisions: "Décisions",
        coming: "À venir",
        awaiting: "Résultat inconnu",
        menu: "Menu",
        topic_general: "Affaires du conseil",
        topic_subsidy: "Subvention",
        topic_settlement: "Transaction",
        topic_works: "Travaux publics",
        topic_money: "Finances publiques",
        topic_property: "Immobilier",
        topic_staff: "Personnel",
        contested_one: "Pas unanime",
        feed_empty:
          "Vous ne suivez encore rien. Ouvrez une liste et choisissez la commune ou le dossier à suivre.",
        feed_cta: "Parcourir les décisions",
        contested: "Non unanimes",
        mandates: "Mandats publics",
        meetings: "Séances",
        follows: "Fil personnel",
        about: "À propos",
        votes_for: "Pour",
        votes_against: "Contre",
        votes_abstained: "Abstention"
      },
      "nl" => %{
        skip: "Naar inhoud",
        language: "Taal",
        sections: "Rubrieken",
        decisions: "Besluiten",
        coming: "Binnenkort",
        awaiting: "Uitkomst onbekend",
        menu: "Menu",
        topic_general: "Raadszaken",
        topic_subsidy: "Subsidie",
        topic_settlement: "Dading",
        topic_works: "Openbare werken",
        topic_money: "Openbare financiën",
        topic_property: "Vastgoed",
        topic_staff: "Personeel",
        contested_one: "Niet unaniem",
        feed_empty:
          "U volgt nog niets. Open een lijst en kies welke gemeente of welk dossier u wilt volgen.",
        feed_cta: "Besluiten bekijken",
        contested: "Niet unaniem",
        mandates: "Openbare mandaten",
        meetings: "Vergaderingen",
        follows: "Persoonlijke feed",
        about: "Over",
        votes_for: "Voor",
        votes_against: "Tegen",
        votes_abstained: "Onthouding"
      }
    }
  end
end
