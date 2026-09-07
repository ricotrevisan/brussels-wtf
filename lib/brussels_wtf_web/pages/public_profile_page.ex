defmodule BrusselsWtfWeb.PublicProfilePage do
  use BrusselsWtfWeb, :dstar_page

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Identity.PublicProfile
  alias BrusselsWtf.Suggestions

  @impl Dstar.Page
  def mount(conn, %{"enterprise_number" => enterprise_number} = params) do
    locale = BrusselsWtfWeb.Locale.resolve(conn, params)

    case Identity.get_public_company_profile(enterprise_number) do
      {:ok, %PublicProfile.Company{} = profile} ->
        assign_profile(conn, profile, locale, "/companies/#{profile.enterprise_number}")

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  def mount(conn, %{"id" => id} = params) do
    locale = BrusselsWtfWeb.Locale.resolve(conn, params)

    case Identity.get_public_person_profile(id) do
      {:ok, %PublicProfile.Person{} = profile} ->
        assign_profile(conn, profile, locale, "/people/#{profile.id}")

      {:redirect, %PublicProfile.Redirect{kind: :person, target_id: target_id}} ->
        conn
        |> Plug.Conn.put_status(308)
        |> Phoenix.Controller.redirect(to: "/people/#{target_id}?lang=#{locale}")

      {:error, :not_found} ->
        not_found(conn)
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
        <nav aria-label={text(@locale, :language)}>
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
      <p class="text-sm text-base-content/70">{profile_label(@locale, @profile)}</p>
      <h1 class="mt-2 text-3xl font-semibold tracking-tight">{profile_name(@profile)}</h1>
      <form method="post" action="/citizen/feed/follows" class="mt-4">
        <input type="hidden" name="_csrf_token" value={@csrf_token} />
        <input type="hidden" name="target_type" value={follow_type(@profile)} />
        <input type="hidden" name="target_identifier" value={follow_identifier(@profile)} />
        <button type="submit" class="btn btn-sm" data-follow-control>{text(@locale, :follow)}</button>
      </form>

      <dl :if={match?(%PublicProfile.Company{}, @profile)} class="mt-6 grid gap-3 sm:grid-cols-2">
        <div>
          <dt class="text-sm text-base-content/70">{text(@locale, :enterprise_number)}</dt>
          <dd class="font-medium">{@profile.enterprise_number}</dd>
        </div>
        <div>
          <dt class="text-sm text-base-content/70">{text(@locale, :status)}</dt>
          <dd class="font-medium">{status_label(@locale, @profile.status)}</dd>
        </div>
      </dl>

      <section
        :if={match?(%PublicProfile.Company{}, @profile)}
        class="mt-9 border-t border-base-300 pt-5"
        aria-labelledby="cbe-citation"
      >
        <h2 id="cbe-citation" class="text-xl font-semibold">{text(@locale, :cbe_source)}</h2>
        <p class="mt-2">{text(@locale, :cbe_description)}</p>
        <dl class="mt-4 grid gap-3 sm:grid-cols-2">
          <div>
            <dt class="text-sm text-base-content/70">{text(@locale, :release_date)}</dt>
            <dd>
              <time datetime={Date.to_iso8601(@profile.cbe.published_on)}>{Date.to_iso8601(
                @profile.cbe.published_on
              )}</time>
            </dd>
          </div>
          <div>
            <dt class="text-sm text-base-content/70">{text(@locale, :checksum)}</dt>
            <dd><code class="break-all text-sm">{@profile.cbe.sha256}</code></dd>
          </div>
        </dl>
      </section>

      <section class="mt-9 border-t border-base-300 pt-5" aria-labelledby="relationships">
        <h2 id="relationships" class="text-xl font-semibold">{text(@locale, :relationships)}</h2>
        <p :if={@profile.relationships == []} class="mt-3 text-base-content/70">
          {text(@locale, :no_relationships)}
        </p>
        <div :for={{group, relationships} <- @relationship_groups} class="mt-4">
          <h3 class="text-lg font-semibold">{text(@locale, group)}</h3>
          <ol class="mt-4 space-y-5">
            <li
              :for={relationship <- relationships}
              id={"fact-" <> relationship.fact_id}
              class="border-l-2 border-base-300 pl-4"
            >
              <h4 class="font-semibold" lang={@locale}>
                {role_label(@locale, relationship)}
              </h4>
              <p :if={relationship.mandate_declaration} class="mt-1 text-sm">
                {text(@locale, :declared_mandate)} · {relationship.mandate_declaration["body"]}
              </p>
              <p :if={relationship.mandate_declaration} class="mt-1 text-sm" lang="fr">
                {relationship.mandate_declaration["role"]}
              </p>
              <p :if={relationship.state == :superseded} class="mt-1 text-sm">
                {text(@locale, :superseded)}
              </p>
              <p class="mt-1">{relationship.subject_name} — {relationship.object_name}</p>
              <p
                :if={relationship.effective_from || relationship.effective_to}
                class="mt-2 text-sm text-base-content/70"
              >
                {text(
                  @locale,
                  if(relationship.mandate_declaration, do: :reporting_period, else: :effective)
                )}
                <time
                  :if={relationship.effective_from}
                  datetime={Date.to_iso8601(relationship.effective_from)}
                >
                  {Date.to_iso8601(relationship.effective_from)}
                </time>
                <span :if={relationship.effective_from && relationship.effective_to}> – </span>
                <time
                  :if={relationship.effective_to}
                  datetime={Date.to_iso8601(relationship.effective_to)}
                >
                  {Date.to_iso8601(relationship.effective_to)}
                </time>
              </p>
              <p class="mt-2 text-sm">
                <a
                  :if={relationship.authoritative_url}
                  href={relationship.authoritative_url}
                  rel="external"
                  class="underline underline-offset-2"
                >{relationship_source(@locale, relationship)}</a>
                <span> · {relationship.evidence_location}</span>
              </p>
              <p class="mt-1 text-sm text-base-content/70">
                {text(@locale, :retrieved)}
                <time datetime={DateTime.to_iso8601(relationship.source_retrieved_at)}>
                  {format_datetime(relationship.source_retrieved_at)}
                </time>
                · {text(@locale, :verified)}
                <time datetime={DateTime.to_iso8601(relationship.verified_at)}>
                  {format_datetime(relationship.verified_at)}
                </time>
              </p>
            </li>
          </ol>
        </div>
      </section>

      <section
        :if={@suggestions_enabled}
        class="mt-9 border-t border-base-300 pt-5"
        aria-labelledby="suggestions"
      >
        <h2 id="suggestions" class="text-xl font-semibold">{text(@locale, :suggestions)}</h2>
        <p class="mt-2 text-sm text-base-content/70">{text(@locale, :suggestion_privacy)}</p>

        <div :if={match?(%PublicProfile.Company{}, @profile)} class="mt-6 grid gap-8 md:grid-cols-2">
          <.suggestion_form
            locale={@locale}
            kind={:ownership}
            action={"/companies/#{@profile.enterprise_number}/suggestions/ownership"}
            csrf_token={@csrf_token}
            honeypot={@honeypot}
          />
          <.suggestion_form
            locale={@locale}
            kind={:correction}
            action={"/companies/#{@profile.enterprise_number}/suggestions/correction"}
            csrf_token={@csrf_token}
            honeypot={@honeypot}
          />
        </div>

        <div :if={match?(%PublicProfile.Person{}, @profile)} class="mt-6 max-w-2xl">
          <.suggestion_form
            locale={@locale}
            kind={:correction}
            action={"/people/#{@profile.id}/suggestions/correction"}
            csrf_token={@csrf_token}
            honeypot={@honeypot}
          />
        </div>
      </section>

      <footer class="mt-12 border-t border-base-300 pt-5 text-sm text-base-content/70">
        {text(@locale, :byline)} Rico Trevisan
      </footer>
    </main>
    """
  end

  defp suggestion_form(assigns) do
    assigns = assign(assigns, :form_id, "#{assigns.kind}-suggestion")

    ~H"""
    <form method="post" action={@action} class="space-y-4">
      <h3 class="font-semibold">{suggestion_heading(@locale, @kind)}</h3>
      <input type="hidden" name="_csrf_token" value={@csrf_token} />
      <div>
        <label for={@form_id <> "-body"} class="block font-medium">{text(@locale, :suggestion)}</label>
        <textarea
          id={@form_id <> "-body"}
          name="body"
          required
          maxlength="10000"
          class="textarea textarea-bordered mt-1 min-h-36 w-full"
        ></textarea>
      </div>
      <div>
        <label for={@form_id <> "-contact"} class="block font-medium">{text(@locale, :contact)}</label>
        <input
          id={@form_id <> "-contact"}
          name="contact"
          maxlength="500"
          autocomplete="email"
          class="input input-bordered mt-1 w-full"
        />
      </div>
      <div class={@honeypot.class} aria-hidden={@honeypot.aria_hidden}>
        <label for={@form_id <> "-website"}>{text(@locale, :website)}</label>
        <input
          id={@form_id <> "-website"}
          name={@honeypot.name}
          tabindex={@honeypot.tabindex}
          autocomplete={@honeypot.autocomplete}
        />
      </div>
      <button type="submit" class="btn">{suggestion_button(@locale, @kind)}</button>
    </form>
    """
  end

  defp assign_profile(conn, profile, locale, resource_path) do
    enabled = Suggestions.enabled?()

    assign(conn,
      page_title: profile_name(profile),
      html_lang: locale,
      resource_path: resource_path,
      locale: locale,
      profile: profile,
      relationship_groups:
        [
          {:current_facts, Enum.filter(profile.relationships, &(&1.state in [nil, :current]))},
          {:dated_history,
           Enum.filter(profile.relationships, &(&1.state in [:ended, :superseded]))}
        ]
        |> Enum.reject(fn {_, facts} -> facts == [] end),
      suggestions_enabled: enabled,
      honeypot: if(enabled, do: Suggestions.honeypot_attributes(), else: nil),
      csrf_token: Plug.CSRFProtection.get_csrf_token()
    )
  end

  defp not_found(conn) do
    conn
    |> Plug.Conn.put_status(404)
    |> Phoenix.Controller.put_view(html: BrusselsWtfWeb.ErrorHTML)
    |> Phoenix.Controller.render(:"404")
  end

  defp follow_type(%PublicProfile.Company{}), do: "legal_entity"
  defp follow_type(%PublicProfile.Person{}), do: "person"
  defp follow_identifier(%PublicProfile.Company{enterprise_number: id}), do: id
  defp follow_identifier(%PublicProfile.Person{id: id}), do: id

  defp profile_name(%PublicProfile.Company{registered_name: name}), do: name
  defp profile_name(%PublicProfile.Person{legal_name: name}), do: name
  defp profile_label(locale, %PublicProfile.Company{}), do: text(locale, :company_profile)
  defp profile_label(locale, %PublicProfile.Person{}), do: text(locale, :person_profile)

  defp status_label("fr", :active), do: "Active"
  defp status_label("fr", :inactive), do: "Inactive"
  defp status_label("nl", :active), do: "Actief"
  defp status_label("nl", :inactive), do: "Inactief"
  defp status_label(_locale, :active), do: "Active"
  defp status_label(_locale, :inactive), do: "Inactive"

  defp role_label(locale, %{mandate_declaration: %{"role_labels" => labels}}),
    do: Map.fetch!(labels, locale)

  defp role_label(locale, relationship), do: kind_label(locale, relationship.kind)

  defp relationship_source(_locale, %{mandate_declaration: %{"reporting_year" => year}}),
    do: "Commune d'Ixelles · Liste des mandats #{year}"

  defp relationship_source(locale, relationship),
    do: source_label(locale, relationship.source_authority)

  defp kind_label("fr", kind), do: Map.fetch!(fr_kinds(), kind)
  defp kind_label("nl", kind), do: Map.fetch!(nl_kinds(), kind)
  defp kind_label(_locale, kind), do: Map.fetch!(en_kinds(), kind)

  defp en_kinds do
    %{
      management: "Management role",
      ownership: "Ownership",
      public_mandate: "Public mandate",
      contract: "Contract",
      donation: "Donation",
      declared_interest: "Declared interest",
      office_holding: "Public office"
    }
  end

  defp fr_kinds do
    %{
      management: "Fonction de gestion",
      ownership: "Propriété",
      public_mandate: "Mandat public",
      contract: "Contrat",
      donation: "Don",
      declared_interest: "Intérêt déclaré",
      office_holding: "Fonction publique"
    }
  end

  defp nl_kinds do
    %{
      management: "Bestuursfunctie",
      ownership: "Eigendom",
      public_mandate: "Openbaar mandaat",
      contract: "Contract",
      donation: "Schenking",
      declared_interest: "Aangegeven belang",
      office_holding: "Openbaar ambt"
    }
  end

  defp source_label("fr", :municipal_decision), do: "Décision communale officielle"
  defp source_label("nl", :municipal_decision), do: "Officieel gemeentelijk besluit"
  defp source_label(_locale, :municipal_decision), do: "Official municipal decision"

  defp suggestion_heading("fr", :ownership), do: "Suggérer une information sur la propriété"
  defp suggestion_heading("nl", :ownership), do: "Eigendomsinformatie voorstellen"
  defp suggestion_heading(_locale, :ownership), do: "Suggest ownership information"
  defp suggestion_heading("fr", :correction), do: "Suggérer une correction"
  defp suggestion_heading("nl", :correction), do: "Een correctie voorstellen"
  defp suggestion_heading(_locale, :correction), do: "Suggest a correction"

  defp suggestion_button(locale, kind), do: suggestion_heading(locale, kind)

  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp text("fr", key), do: Map.fetch!(fr_text(), key)
  defp text("nl", key), do: Map.fetch!(nl_text(), key)
  defp text(_locale, key), do: Map.fetch!(en_text(), key)

  defp en_text do
    %{
      skip: "Skip to content",
      follow: "Follow updates about this profile",
      language: "Language",
      company_profile: "Company profile",
      person_profile: "Person profile",
      enterprise_number: "Enterprise number",
      status: "Status",
      cbe_source: "Company register source",
      cbe_description: "Crossroads Bank for Enterprises (CBE) Open Data",
      release_date: "Release date",
      checksum: "SHA-256 checksum",
      relationships: "Verified facts",
      current_facts: "Current facts",
      dated_history: "Dated history",
      declared_mandate: "Declared mandate",
      reporting_period: "Declared period:",
      superseded: "Superseded by a corrected declaration",
      no_relationships: "No verified public relationships are available.",
      effective: "Effective:",
      retrieved: "Retrieved",
      verified: "Verified",
      suggestions: "Private suggestions",
      suggestion_privacy:
        "Your text and optional contact stay private. A suggestion is only a lead and cannot publish or verify a fact.",
      suggestion: "Suggestion",
      contact: "Private contact (optional)",
      website: "Website",
      byline: "By"
    }
  end

  defp fr_text do
    %{
      skip: "Aller au contenu",
      follow: "Suivre les mises à jour de ce profil",
      language: "Langue",
      company_profile: "Profil d’entreprise",
      person_profile: "Profil de personne",
      enterprise_number: "Numéro d’entreprise",
      status: "Statut",
      cbe_source: "Source du registre des entreprises",
      cbe_description: "Banque-Carrefour des Entreprises (BCE) — données ouvertes",
      release_date: "Date de la publication",
      checksum: "Somme de contrôle SHA-256",
      relationships: "Faits vérifiés",
      current_facts: "Faits actuels",
      dated_history: "Historique daté",
      declared_mandate: "Mandat déclaré",
      reporting_period: "Période déclarée :",
      superseded: "Remplacé par une déclaration corrigée",
      no_relationships: "Aucune relation publique vérifiée n’est disponible.",
      effective: "En vigueur :",
      retrieved: "Récupérée",
      verified: "Vérifiée",
      suggestions: "Suggestions privées",
      suggestion_privacy:
        "Votre texte et votre éventuel contact restent privés. Une suggestion est seulement une piste et ne peut ni publier ni vérifier un fait.",
      suggestion: "Suggestion",
      contact: "Contact privé (facultatif)",
      website: "Site web",
      byline: "Par"
    }
  end

  defp nl_text do
    %{
      skip: "Naar inhoud",
      follow: "Updates over dit profiel volgen",
      language: "Taal",
      company_profile: "Bedrijfsprofiel",
      person_profile: "Persoonsprofiel",
      enterprise_number: "Ondernemingsnummer",
      status: "Status",
      cbe_source: "Bron van het ondernemingsregister",
      cbe_description: "Kruispuntbank van Ondernemingen (KBO) — Open Data",
      release_date: "Publicatiedatum",
      checksum: "SHA-256-controlesom",
      relationships: "Geverifieerde feiten",
      current_facts: "Actuele feiten",
      dated_history: "Gedateerde geschiedenis",
      declared_mandate: "Aangegeven mandaat",
      reporting_period: "Aangegeven periode:",
      superseded: "Vervangen door een gecorrigeerde aangifte",
      no_relationships: "Er zijn geen geverifieerde openbare relaties beschikbaar.",
      effective: "Van kracht:",
      retrieved: "Opgehaald",
      verified: "Geverifieerd",
      suggestions: "Privésuggesties",
      suggestion_privacy:
        "Uw tekst en optionele contactgegevens blijven privé. Een suggestie is alleen een aanwijzing en kan geen feit publiceren of verifiëren.",
      suggestion: "Suggestie",
      contact: "Privécontact (optioneel)",
      website: "Website",
      byline: "Door"
    }
  end
end
