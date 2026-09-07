defmodule BrusselsWtfWeb.PublicationInfoPage do
  use BrusselsWtfWeb, :dstar_page

  @impl Dstar.Page
  def mount(conn, params) do
    locale = BrusselsWtfWeb.Locale.resolve(conn, params)
    coverage? = conn.request_path == "/coverage"

    assign(conn,
      locale: locale,
      html_lang: locale,
      resource_path: conn.request_path,
      page_title: text(locale, if(coverage?, do: :coverage, else: :about)),
      coverage?: coverage?,
      status:
        if(coverage?, do: BrusselsWtf.CoverageStatus.snapshot(BrusselsWtfWeb.MeetingTime.today()))
    )
  end

  @impl Dstar.Page
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-4xl px-4 py-6">
      <header class="flex justify-between gap-4">
        <a data-reader-back href={"/?lang=#{@locale}"} class="font-semibold">brussels.wtf</a>
        <nav aria-label="Language" class="flex gap-3">
          <a
            :for={locale <- ~w(fr nl en)}
            href={"#{@resource_path}?lang=#{locale}"}
            hreflang={locale}
            lang={locale}
            class="underline"
          >{String.upcase(locale)}</a>
        </nav>
      </header>
      <h1 class="mt-8 text-2xl font-semibold">{@page_title}</h1>
      <%= if @coverage? do %>
        <p class="mt-4 leading-7">{text(@locale, :scope)}</p>
        <p class="mt-3">
          {text(@locale, :window)}: {Date.to_iso8601(@status.first)} – {Date.to_iso8601(@status.last)}
        </p>
        <section :for={commune <- @status.communes} class="mt-8 border-t border-base-300 pt-4">
          <h2 class="text-xl font-semibold">{commune["name"]}</h2>
          <p class="mt-2 text-sm">
            {text(@locale, :checked)}: {timestamp(commune["checked_at"], @locale)}
          </p>
          <p :if={commune["attempted_at"] != commune["checked_at"]} class="mt-1 text-sm">
            {text(@locale, :attempted)}: {timestamp(commune["attempted_at"], @locale)}
          </p>
          <p class="mt-2">
            <a href={commune["index_url"]} class="underline">{text(@locale, :official)}</a>
          </p>
          <ul class="mt-3 space-y-4">
            <li :for={meeting <- Enum.filter(@status.meetings, &(&1["slug"] == commune["slug"]))}>
              <time datetime={Date.to_iso8601(meeting["scheduled_on"])}>{Date.to_iso8601(
                meeting["scheduled_on"]
              )}</time>
              <%= if meeting["published"] do %>
                ·
                <a
                  href={"/meetings/#{commune["slug"]}/#{URI.encode(meeting["meeting_identifier"], &URI.char_unreserved?/1)}?lang=#{@locale}"}
                  class="underline"
                >{text(@locale, :partial)}</a>
                <p class="text-sm">
                  {text(@locale, :revision)}: {timestamp(meeting["published_at"], @locale)}
                </p>
              <% else %>
                · {text(@locale, :pending)}
              <% end %>
              <p class="text-sm text-base-content/70">
                {text(@locale, if(meeting["final_source_seen"], do: :final_seen, else: :final_absent))}
              </p>
            </li>
          </ul>
          <p :if={not Enum.any?(@status.meetings, &(&1["slug"] == commune["slug"]))} class="mt-3">
            {text(@locale, :none)}
          </p>
        </section>
      <% else %>
        <p
          :for={key <- [:purpose, :method, :outcomes, :corrections, :retention]}
          class="mt-5 leading-7"
        >
          {text(@locale, key)}
        </p>
      <% end %>
      <BrusselsWtfWeb.PublicationComponents.footer locale={@locale} />
    </main>
    """
  end

  defp timestamp(nil, locale), do: text(locale, :unverified)
  defp timestamp(%NaiveDateTime{} = date, _locale), do: NaiveDateTime.to_iso8601(date) <> " UTC"
  defp timestamp(date, _locale), do: DateTime.to_iso8601(date)

  defp text(locale, key) do
    %{
      "en" => %{
        coverage: "Coverage and source checks",
        about: "About brussels.wtf",
        scope:
          "This is a selected publication, not a complete council register. Below are documents discovered for the last 90 days and next 30 days. A discovered document is not necessarily processed or published. Older selected meetings remain on the timeline. Index checks exclude archival replays and do not prove that every document was downloaded.",
        window: "Document discovery window",
        checked: "Last successful official index check",
        attempted: "Latest check attempt (not confirmed successful)",
        official: "Open the official municipal index",
        partial: "Read selected coverage",
        revision: "Publication revision",
        pending: "Source discovered; coverage not yet published",
        final_seen:
          "A final-record source was discovered; publication still depends on checking its evidence.",
        final_absent:
          "No final-record source discovered for this meeting. This does not establish that the municipality has not published one.",
        none:
          "No meeting documents have been discovered in this window. This is a coverage gap, not proof that no meeting occurred.",
        unverified: "Not recorded",
        purpose:
          "brussels.wtf helps readers follow council activity in Ixelles, Uccle, Forest and the City of Brussels. Rico Trevisan is responsible for this independent publication. It is not an official municipal service.",
        method:
          "Explanations are AI-generated from retained official source evidence; French is the editorial source for machine translations into Dutch and English. A human-reviewed label is used only when a human review actually took place. Citations retain the official location, retrieval date and checksum; original-language excerpts remain source material.",
        outcomes:
          "An agenda establishes what was scheduled, not what was adopted. When a meeting date passes without a verified final record, its items move to ‘Awaiting documented outcome’. This changes neither their evidence nor their outcome. Dossiers connect continuing matters only when the evidence supports that link.",
        corrections:
          "Use ‘Report an error in this item’ below any published item to send a private correction with its exact context. Reports enter editorial review and never change public facts automatically. Factual corrections update all three languages together and retain dated publication history. Incorrect dossier links can also be reported from the dossier page.",
        retention:
          "You do not need an account to report an error. Contact details are optional and private, retained for at most 90 days and at most 30 days after a decision. Report text is retained for up to 365 days. Do not include sensitive personal details that are unnecessary for checking the claim."
      },
      "fr" => %{
        coverage: "Couverture et vérification des sources",
        about: "À propos de brussels.wtf",
        scope:
          "Cette publication est une sélection, pas un registre communal complet. Voici les documents découverts pour les 90 derniers jours et les 30 prochains jours. Un document découvert n’est pas nécessairement traité ou publié. Les anciennes réunions sélectionnées restent dans le fil. Les vérifications d’index excluent les reprises d’archives et ne prouvent pas le téléchargement de tous les documents.",
        window: "Période de découverte des documents",
        checked: "Dernière vérification réussie de l’index officiel",
        attempted: "Dernière tentative (réussite non confirmée)",
        official: "Ouvrir l’index communal officiel",
        partial: "Lire la sélection publiée",
        revision: "Révision de publication",
        pending: "Source découverte ; couverture non encore publiée",
        final_seen:
          "Une source de résultat final a été découverte ; sa publication dépend encore de la vérification des preuves.",
        final_absent:
          "Aucune source de résultat final découverte pour cette réunion. Cela ne prouve pas que la commune n’en a pas publié.",
        none:
          "Aucun document de réunion découvert dans cette période. C’est une lacune de couverture, pas la preuve d’une absence de réunion.",
        unverified: "Non enregistré",
        purpose:
          "brussels.wtf aide à suivre les conseils d’Ixelles, Uccle, Forest et de la Ville de Bruxelles. Rico Trevisan est responsable de cette publication indépendante. Ce n’est pas un service communal officiel.",
        method:
          "Les explications sont générées par IA à partir de preuves officielles conservées ; le français est la source éditoriale des traductions automatiques en néerlandais et en anglais. La mention de révision humaine est utilisée uniquement lorsqu’elle a réellement eu lieu. Les citations conservent l’emplacement officiel, la date de collecte et l’empreinte du document ; les extraits restent dans leur langue d’origine.",
        outcomes:
          "Un ordre du jour établit ce qui était prévu, pas ce qui a été adopté. Après la date d’une réunion, sans résultat final vérifié, ses points passent dans « Résultat documenté en attente ». Cela ne modifie ni leurs preuves ni leur résultat. Les dossiers relient des affaires continues uniquement lorsque les preuves le permettent.",
        corrections:
          "Utilisez « Signaler une erreur dans ce point » sous un point publié pour transmettre une correction privée avec son contexte exact. Les signalements vont à la rédaction et ne modifient jamais automatiquement les faits publics. Les corrections factuelles mettent à jour les trois langues ensemble et conservent un historique daté. Les liens de dossier incorrects peuvent aussi être signalés depuis le dossier.",
        retention:
          "Aucun compte n’est requis pour signaler une erreur. Les coordonnées sont facultatives et privées, conservées au maximum 90 jours et au maximum 30 jours après une décision. Le texte est conservé jusqu’à 365 jours. Évitez les informations personnelles sensibles inutiles à la vérification."
      },
      "nl" => %{
        coverage: "Dekking en broncontroles",
        about: "Over brussels.wtf",
        scope:
          "Dit is een selectie, geen volledig gemeenteregister. Hieronder staan documenten die voor de afgelopen 90 en komende 30 dagen zijn ontdekt. Een ontdekt document is niet noodzakelijk verwerkt of gepubliceerd. Oudere geselecteerde vergaderingen blijven in het overzicht. Indexcontroles tellen archiefherhalingen niet mee en bewijzen niet dat alle documenten zijn gedownload.",
        window: "Periode voor documentontdekking",
        checked: "Laatste geslaagde controle van de officiële index",
        attempted: "Laatste poging (succes niet bevestigd)",
        official: "Open de officiële gemeentelijke index",
        partial: "Lees de gepubliceerde selectie",
        revision: "Publicatierevisie",
        pending: "Bron ontdekt; verslag nog niet gepubliceerd",
        final_seen:
          "Een bron met definitieve resultaten is ontdekt; publicatie vereist nog controle van het bewijs.",
        final_absent:
          "Geen bron met definitieve resultaten ontdekt voor deze vergadering. Dit bewijst niet dat de gemeente er geen heeft gepubliceerd.",
        none:
          "Geen vergaderdocumenten ontdekt in deze periode. Dit is een lacune in de dekking, geen bewijs dat er geen vergadering was.",
        unverified: "Niet vastgelegd",
        purpose:
          "brussels.wtf helpt lezers de raden van Elsene, Ukkel, Vorst en de Stad Brussel te volgen. Rico Trevisan is verantwoordelijk voor deze onafhankelijke publicatie. Dit is geen officiële gemeentedienst.",
        method:
          "De uitleg wordt met AI gegenereerd op basis van bewaard officieel bronbewijs; Frans is de redactionele bron voor machinevertalingen naar Nederlands en Engels. Het label voor menselijke controle wordt alleen gebruikt als die daadwerkelijk plaatsvond. Citaten behouden de officiële vindplaats, ophaaldatum en checksum; bronfragmenten blijven in hun oorspronkelijke taal.",
        outcomes:
          "Een agenda legt vast wat gepland was, niet wat aangenomen werd. Na de vergaderdatum gaan punten zonder geverifieerd eindverslag naar ‘In afwachting van gedocumenteerde uitkomst’. Dat verandert hun bewijs of uitkomst niet. Dossiers verbinden doorlopende zaken alleen wanneer het bewijs dat ondersteunt.",
        corrections:
          "Gebruik ‘Een fout in dit punt melden’ onder een gepubliceerd punt om een privécorrectie met de exacte context te sturen. Meldingen gaan naar de redactie en veranderen publieke feiten nooit automatisch. Feitelijke correcties werken de drie talen samen bij en bewaren gedateerde publicatiegeschiedenis. Onjuiste dossierkoppelingen kunnen ook vanuit het dossier worden gemeld.",
        retention:
          "U hebt geen account nodig om een fout te melden. Contactgegevens zijn optioneel en privé en worden maximaal 90 dagen en maximaal 30 dagen na een beslissing bewaard. Meldingstekst wordt maximaal 365 dagen bewaard. Vermeld geen gevoelige persoonsgegevens die niet nodig zijn om de bewering te controleren."
      }
    }[locale][key]
  end
end
