defmodule BrusselsWtfWeb.FollowCollectionController do
  use BrusselsWtfWeb, :controller
  alias BrusselsWtf.Follow

  @session_key :follow_management_collection_id

  def create(conn, _params) do
    case Follow.create_collection() do
      {:ok, _collection, secret} ->
        management_url =
          "/collections/manage-capability#capability=" <> URI.encode_www_form(secret)

        conn
        |> private_headers()
        |> html("""
        <!doctype html><html lang="en"><head><meta name="referrer" content="no-referrer"><meta name="robots" content="noindex, nofollow"><title>Collection created</title></head><body>
        <main><h1>Collection created</h1><p>Save this management link. It is the only way to recover management access.</p><p><a id="management-link" href="#{management_url}">Manage collection</a></p></main>
        </body></html>
        """)

      _ ->
        send_resp(conn, 422, "Collection could not be created")
    end
  end

  def bootstrap(conn, _params) do
    csrf = Plug.CSRFProtection.get_csrf_token()

    conn
    |> private_headers()
    |> html("""
    <!doctype html><html lang="en"><head><meta name="referrer" content="no-referrer"><meta name="robots" content="noindex, nofollow"><title>Open collection management</title></head><body>
    <main><p>Opening collection management…</p></main>
    <script>
    (() => {
      const capability = new URLSearchParams(location.hash.slice(1)).get("capability");
      history.replaceState(null, "", location.pathname);
      if (!capability) { document.querySelector("p").textContent = "Invalid management link"; return; }
      fetch(location.pathname, {method: "POST", credentials: "same-origin", headers: {"x-csrf-token": "#{csrf}", "x-follow-capability": capability}})
        .then(response => { if (!response.ok) throw new Error("invalid"); location.replace("/collections/manage"); })
        .catch(() => { document.querySelector("p").textContent = "Invalid management link"; });
    })();
    </script></body></html>
    """)
  end

  def exchange(conn, _params) do
    secret = conn |> get_req_header("x-follow-capability") |> List.first()

    case Follow.exchange(secret) do
      {:ok, collection} ->
        conn
        |> configure_session(renew: true)
        |> put_session(@session_key, collection.id)
        |> private_headers()
        |> send_resp(204, "")

      _ ->
        conn |> private_headers() |> send_resp(404, "Not found")
    end
  end

  def updates(conn, %{"targets" => targets}) do
    json(conn, %{updates: BrusselsWtf.Follow.PublicUpdates.list(targets, conn.assigns.locale)})
  end

  def updates(conn, _), do: json(conn, %{updates: []})

  def feed(conn, _params) do
    locale = conn.assigns.locale
    csrf = Plug.CSRFProtection.get_csrf_token()

    case BrusselsWtf.Accounts.authenticate_session(get_session(conn, :citizen_session_id)) do
      {:ok, citizen} ->
        {:ok, updates} = Follow.registered_feed(citizen)
        retention_notice = retention_notice(citizen, locale)

        items =
          Enum.map_join(updates, "", fn update ->
            read = if update.read_at, do: copy(locale, :read), else: copy(locale, :unread)

            url = localized_update_url(update.public_url, locale)

            label =
              "#{copy(locale, {:event, update.event_kind})} — " <>
                "#{copy(locale, {:type, update.target_type})}"

            ~s(<li data-update-id="#{update.id}" data-read="#{not is_nil(update.read_at)}"><a href="#{escape(url)}">#{escape(label)}</a> <span>#{read}</span><form method="post" action="/citizen/feed/#{update.id}/read"><input type="hidden" name="_csrf_token" value="#{csrf}"><button>#{copy(locale, :mark_read)}</button></form></li>)
          end)

        html(
          conn,
          ~s(<!doctype html><html lang="#{locale}"><head><title>#{copy(locale, :feed)}</title></head><body><main><h1>#{copy(locale, :feed)}</h1><p>#{copy(locale, :synced)}</p>#{retention_notice}<ul data-registered-feed>#{items}</ul></main></body></html>)
        )

      _ ->
        html(
          conn,
          ~s(<!doctype html><html lang="#{locale}"><head><meta name="csrf-token" content="#{csrf}"><title>#{copy(locale, :feed)}</title><script defer src="/assets/js/personal_feed_entry.js"></script></head><body><main><h1>#{copy(locale, :feed)}</h1><p>#{copy(locale, :privacy)}</p><ul data-personal-feed></ul><noscript>#{copy(locale, :javascript)}</noscript></main></body></html>)
        )
    end
  end

  def follow(conn, %{"target_type" => type, "target_identifier" => identifier}) do
    with {:ok, citizen} <-
           BrusselsWtf.Accounts.authenticate_session(get_session(conn, :citizen_session_id)),
         type when type != :invalid <- parse_type(type),
         {:ok, [_ | _]} <- Follow.import_citizen_follows(citizen, [{type, identifier}]) do
      redirect(conn, to: "/feed?lang=#{conn.assigns.locale}")
    else
      _ -> send_resp(conn, 422, "")
    end
  end

  def mark_read(conn, %{"id" => id}) do
    with {:ok, citizen} <-
           BrusselsWtf.Accounts.authenticate_session(get_session(conn, :citizen_session_id)),
         {:ok, _} <- Follow.mark_read(citizen, id) do
      redirect(conn, to: "/feed?lang=#{conn.assigns.locale}")
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  def registered_manage(conn, %{"id" => id}) do
    with {:ok, citizen} <-
           BrusselsWtf.Accounts.authenticate_session(get_session(conn, :citizen_session_id)),
         {:ok, collection} <- Follow.owner_collection(citizen, id) do
      csrf = Plug.CSRFProtection.get_csrf_token()
      locale = conn.assigns.locale

      members =
        Enum.map_join(collection.members, "", fn m ->
          "<li>#{escape(m.target_type)}: #{escape(m.target_identifier)}</li>"
        end)

      html(
        conn,
        ~s(<!doctype html><html lang="#{locale}"><body><main><h1>#{copy(locale, :manage_private)}</h1><p>#{copy(locale, :owner_only)}</p><ul>#{members}</ul><form method="post" action="/citizen/collections/#{id}/visibility"><input type="hidden" name="_csrf_token" value="#{csrf}"><select name="visibility">#{visibility_options(collection.visibility)}</select><button>#{copy(locale, :change)}</button></form><form method="post" action="/citizen/collections/#{id}/members"><input type="hidden" name="_csrf_token" value="#{csrf}"><select name="target_type"><option>dossier</option><option>person</option><option value="legal_entity">legal entity</option><option>commune</option></select><input name="target_identifier" required><button>#{copy(locale, :add)}</button></form><form method="post" action="/citizen/collections/#{id}/grants"><input type="hidden" name="_csrf_token" value="#{csrf}"><input name="citizen_id" required><button>#{copy(locale, :grant)}</button></form></main></body></html>)
      )
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  def registered_visibility(conn, %{"id" => id, "visibility" => visibility}) do
    with {:ok, c} <-
           BrusselsWtf.Accounts.authenticate_session(get_session(conn, :citizen_session_id)),
         {:ok, _} <- Follow.owner_set_visibility(c, id, parse_visibility(visibility)),
         do: redirect(conn, to: "/citizen/collections/#{id}")
  end

  def registered_add(conn, %{"id" => id, "target_type" => type, "target_identifier" => identifier}) do
    with {:ok, c} <-
           BrusselsWtf.Accounts.authenticate_session(get_session(conn, :citizen_session_id)),
         {:ok, _} <- Follow.owner_add_member(c, id, parse_type(type), identifier),
         do: redirect(conn, to: "/citizen/collections/#{id}")
  end

  def registered_grant(conn, %{"id" => id, "citizen_id" => recipient}) do
    with {:ok, c} <-
           BrusselsWtf.Accounts.authenticate_session(get_session(conn, :citizen_session_id)),
         {:ok, _} <- Follow.grant_private_view(c, id, recipient),
         do: redirect(conn, to: "/citizen/collections/#{id}")
  end

  def registered_revoke(conn, %{"id" => id, "grant_id" => grant}) do
    with {:ok, c} <-
           BrusselsWtf.Accounts.authenticate_session(get_session(conn, :citizen_session_id)),
         :ok <- Follow.revoke_private_view(c, id, grant),
         do: redirect(conn, to: "/citizen/collections/#{id}")
  end

  def show(conn, %{"token" => token}) do
    case Follow.view(token) do
      {:ok, collection} -> render_collection(conn, collection, false)
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  def manage(conn, _params) do
    with {:ok, id} <- management_id(conn),
         {:ok, collection} <- Follow.manage_session(id) do
      render_collection(conn, collection, true)
    else
      _ -> conn |> private_headers() |> send_resp(404, "Not found")
    end
  end

  def update(conn, %{"visibility" => visibility}) do
    with {:ok, id} <- management_id(conn),
         {:ok, _} <- Follow.set_visibility_session(id, parse_visibility(visibility)) do
      conn |> private_headers() |> redirect(to: "/collections/manage")
    else
      _ -> conn |> private_headers() |> send_resp(422, "Invalid collection change")
    end
  end

  def add(conn, %{"target_type" => type, "target_identifier" => identifier}) do
    with {:ok, id} <- management_id(conn),
         {:ok, _} <- Follow.add_member_session(id, parse_type(type), identifier) do
      conn |> private_headers() |> redirect(to: "/collections/manage")
    else
      _ -> conn |> private_headers() |> send_resp(422, "This public resource cannot be added")
    end
  end

  def remove(conn, %{"target_type" => type, "target_identifier" => identifier}) do
    with {:ok, id} <- management_id(conn),
         {:ok, _} <- Follow.remove_member_session(id, parse_type(type), identifier) do
      conn |> private_headers() |> redirect(to: "/collections/manage")
    else
      _ -> conn |> private_headers() |> send_resp(404, "Not found")
    end
  end

  defp management_id(conn) do
    case get_session(conn, @session_key) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp render_collection(conn, collection, management?) do
    conn =
      conn
      |> put_resp_header("referrer-policy", "no-referrer")
      |> then(fn conn ->
        if collection.visibility == :public and not management?,
          do: conn,
          else: put_resp_header(conn, "x-robots-tag", "noindex, nofollow")
      end)
      |> then(fn conn -> if management?, do: private_headers(conn), else: conn end)

    csrf_token = Plug.CSRFProtection.get_csrf_token()

    members =
      Enum.map_join(collection.members, "", fn member ->
        remove =
          if management?,
            do: """
              <form action="/collections/manage/members" method="post">
                <input type="hidden" name="_csrf_token" value="#{csrf_token}"><input type="hidden" name="_method" value="delete">
                <input type="hidden" name="target_type" value="#{escape(member.target_type)}"><input type="hidden" name="target_identifier" value="#{escape(member.target_identifier)}">
                <button type="submit">Remove</button>
              </form>
            """,
            else: ""

        select =
          if management?,
            do: "",
            else:
              ~s(<label><input type="checkbox" data-follow-target data-type="#{escape(member.target_type)}" data-identifier="#{escape(member.target_identifier)}" checked> #{copy(conn.assigns.locale, :select)}</label>)

        "<li>#{copy(conn.assigns.locale, {:type, member.target_type})}: #{escape(member.target_identifier)}#{select}#{remove}</li>"
      end)

    management =
      if management?,
        do: """
          <p>Management access</p><p><a href="/collections/#{escape(collection.view_token)}">Public view</a></p>
          <form action="/collections/manage" method="post"><input type="hidden" name="_csrf_token" value="#{csrf_token}"><input type="hidden" name="_method" value="patch">
            <label>Visibility <select name="visibility">#{visibility_options(collection.visibility)}</select></label><button type="submit">Change visibility</button>
          </form>
          <form action="/collections/manage/members" method="post"><input type="hidden" name="_csrf_token" value="#{csrf_token}">
            <label>Resource type <select name="target_type"><option value="dossier">Dossier</option><option value="person">Person</option><option value="legal_entity">Legal entity</option><option value="commune">Commune</option></select></label>
            <label>Stable public identifier <input name="target_identifier" required></label><button type="submit">Add public resource</button>
          </form>
        """,
        else: ""

    import =
      if management?,
        do: "",
        else:
          ~s(<form data-follow-import><ul>#{members}</ul><button type="submit">#{copy(conn.assigns.locale, :import)}</button></form>)

    member_list = if management?, do: "<ul>#{members}</ul>", else: import

    html(conn, """
    <!doctype html><html lang="#{conn.assigns.locale}"><head><meta name="robots" content="#{if collection.visibility == :public and not management?, do: "index, follow", else: "noindex, nofollow"}"><title>#{escape(collection.title)}</title><script defer src="/assets/js/personal_feed_entry.js"></script></head><body><main><h1>#{escape(collection.title)}</h1>#{management}#{member_list}<p>#{copy(conn.assigns.locale, :collection_scope)}</p><p>#{copy(conn.assigns.locale, :snapshot)}</p></main></body></html>
    """)
  end

  defp copy("fr", :feed), do: "Fil personnel"
  defp copy("nl", :feed), do: "Persoonlijke feed"
  defp copy(_, :feed), do: "Personal feed"

  defp copy("fr", :synced), do: "Votre fil privé est synchronisé entre vos sessions."
  defp copy("nl", :synced), do: "Uw privéfeed wordt tussen sessies gesynchroniseerd."
  defp copy(_, :synced), do: "Your private feed is synced across sessions."
  defp copy("fr", :read), do: "Lu"
  defp copy("nl", :read), do: "Gelezen"
  defp copy(_, :read), do: "Read"
  defp copy("fr", :unread), do: "Non lu"
  defp copy("nl", :unread), do: "Ongelezen"
  defp copy(_, :unread), do: "Unread"
  defp copy("fr", :mark_read), do: "Marquer comme lu"
  defp copy("nl", :mark_read), do: "Als gelezen markeren"
  defp copy(_, :mark_read), do: "Mark read"

  defp copy("fr", :manage_private), do: "Gérer la collection"
  defp copy("nl", :manage_private), do: "Collectie beheren"
  defp copy(_, :manage_private), do: "Manage collection"

  defp copy("fr", :owner_only),
    do: "Seul le propriétaire peut modifier. Les invités peuvent uniquement consulter."

  defp copy("nl", :owner_only),
    do: "Alleen de eigenaar kan wijzigen. Genodigden kunnen alleen bekijken."

  defp copy(_, :owner_only), do: "Only the owner can edit. Invited citizens can only view."
  defp copy("fr", :change), do: "Modifier"
  defp copy("nl", :change), do: "Wijzigen"
  defp copy(_, :change), do: "Change"
  defp copy("fr", :add), do: "Ajouter"
  defp copy("nl", :add), do: "Toevoegen"
  defp copy(_, :add), do: "Add"
  defp copy("fr", :grant), do: "Inviter en lecture seule"
  defp copy("nl", :grant), do: "Uitnodigen als alleen-lezen"
  defp copy(_, :grant), do: "Invite view-only"

  defp copy("fr", :privacy),
    do:
      "Vos suivis, notifications et états de lecture restent uniquement dans ce navigateur. Ils ne sont pas synchronisés et sont perdus si ses données sont effacées."

  defp copy("nl", :privacy),
    do:
      "Uw gevolgde items, meldingen en leesstatus blijven alleen in deze browser. Ze synchroniseren niet en gaan verloren wanneer browsergegevens worden gewist."

  defp copy(_, :privacy),
    do:
      "Your follows, notifications, and read state stay only in this browser. They do not sync and are lost when browser data is cleared."

  defp copy("fr", :javascript), do: "Ce fil local nécessite JavaScript."
  defp copy("nl", :javascript), do: "Deze lokale feed vereist JavaScript."
  defp copy(_, :javascript), do: "This browser-local feed requires JavaScript."

  defp copy("fr", :collection_scope),
    do:
      "Cette collection contient uniquement des ressources publiques. Elle ne contient aucun état de lecture ni notification."

  defp copy("nl", :collection_scope),
    do: "Deze collectie bevat alleen openbare bronnen. Ze bevat geen leesstatus of meldingen."

  defp copy(_, :collection_scope),
    do: "This collection contains public resources only. It has no read state or notifications."

  defp copy("fr", {:type, type}),
    do:
      %{
        dossier: "Dossier",
        person: "Personne",
        legal_entity: "Entité juridique",
        commune: "Commune"
      }[type]

  defp copy("nl", {:type, type}),
    do:
      %{dossier: "Dossier", person: "Persoon", legal_entity: "Rechtspersoon", commune: "Gemeente"}[
        type
      ]

  defp copy(_, {:type, type}),
    do:
      %{dossier: "Dossier", person: "Person", legal_entity: "Legal entity", commune: "Commune"}[
        type
      ]

  defp copy(locale, {:event, event}) do
    labels = %{
      "en" => %{
        linked_agenda_item: "Agenda item linked",
        decision: "Documented decision",
        correction: "Factual correction",
        merge: "Dossiers merged",
        split: "Dossier split",
        relevant_council_item: "Relevant council item",
        published_meeting_page: "Meeting page published",
        publication_revision_new_decisions: "New documented decisions",
        verified_public_mandate: "Verified public mandate",
        verified_management_role: "Verified management role",
        contract_award: "Verified contract award"
      },
      "fr" => %{
        linked_agenda_item: "Point lié au dossier",
        decision: "Décision documentée",
        correction: "Correction factuelle",
        merge: "Dossiers fusionnés",
        split: "Dossier scindé",
        relevant_council_item: "Point pertinent du conseil",
        published_meeting_page: "Page de séance publiée",
        publication_revision_new_decisions: "Nouvelles décisions documentées",
        verified_public_mandate: "Mandat public vérifié",
        verified_management_role: "Fonction de gestion vérifiée",
        contract_award: "Attribution de marché vérifiée"
      },
      "nl" => %{
        linked_agenda_item: "Agendapunt aan dossier gekoppeld",
        decision: "Gedocumenteerde beslissing",
        correction: "Feitelijke correctie",
        merge: "Dossiers samengevoegd",
        split: "Dossier gesplitst",
        relevant_council_item: "Relevant gemeenteraadspunt",
        published_meeting_page: "Vergaderpagina gepubliceerd",
        publication_revision_new_decisions: "Nieuwe gedocumenteerde beslissingen",
        verified_public_mandate: "Geverifieerd openbaar mandaat",
        verified_management_role: "Geverifieerde bestuursfunctie",
        contract_award: "Geverifieerde overheidsopdracht"
      }
    }

    labels |> Map.fetch!(locale) |> Map.get(event, copy(locale, :update))
  end

  defp copy("fr", :update), do: "Mise à jour publique"
  defp copy("nl", :update), do: "Openbare update"
  defp copy(_, :update), do: "Public update"

  defp copy("fr", :select), do: "Sélectionner"
  defp copy("nl", :select), do: "Selecteren"
  defp copy(_, :select), do: "Select"
  defp copy("fr", :import), do: "Importer la sélection dans mon fil personnel"
  defp copy("nl", :import), do: "Selectie in mijn persoonlijke feed importeren"
  defp copy(_, :import), do: "Import selected into my personal feed"

  defp copy("fr", :snapshot),
    do:
      "Les suivis importés restent uniquement dans ce navigateur. Ils ne sont pas synchronisés et sont perdus si ses données sont effacées. L’import est un instantané : les modifications ultérieures de la collection ne changent pas vos suivis."

  defp copy("nl", :snapshot),
    do:
      "Geïmporteerde gevolgde items blijven alleen in deze browser. Ze synchroniseren niet en gaan verloren wanneer browsergegevens worden gewist. De import is een momentopname: latere collectiewijzigingen veranderen uw gevolgde items niet."

  defp copy(_, :snapshot),
    do:
      "Imported follows stay only in this browser. They do not sync and are lost when browser data is cleared. Import is a snapshot; later collection changes do not alter your follows."

  defp localized_update_url(url, locale) do
    uri = URI.parse(url)

    query =
      uri.query
      |> Kernel.||("" |> URI.decode_query() |> Map.put("lang", locale) |> URI.encode_query())

    URI.to_string(%{uri | query: query})
  end

  defp private_headers(conn),
    do:
      conn
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-robots-tag", "noindex, nofollow")

  defp visibility_options(current),
    do:
      Enum.map_join([:public, :unlisted, :private], fn v ->
        "<option value=\"#{v}\"#{if v == current, do: " selected", else: ""}>#{v}</option>"
      end)

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp parse_type(v) when v in ~w(dossier person legal_entity commune),
    do: String.to_existing_atom(v)

  defp parse_type(_), do: :invalid
  defp parse_visibility(v) when v in ~w(public unlisted private), do: String.to_existing_atom(v)
  defp parse_visibility(_), do: :invalid

  defp retention_notice(citizen, locale) do
    case BrusselsWtf.Accounts.inactivity_notice(citizen) do
      {:warning, days, deletion_at} ->
        date = Calendar.strftime(deletion_at, "%Y-%m-%d")

        text =
          case locale do
            "fr" ->
              "Votre compte sera supprimé dans #{days} jours (#{date}). Connectez-vous pour le conserver."

            "nl" ->
              "Uw account wordt over #{days} dagen verwijderd (#{date}). Meld u aan om het te behouden."

            _ ->
              "Your account will be deleted in #{days} days (#{date}). Sign in to keep it."
          end

        ~s(<aside data-inactivity-warning>#{escape(text)}</aside>)

      {:deadline, deletion_at} ->
        date = Calendar.strftime(deletion_at, "%Y-%m-%d")
        ~s(<aside data-inactivity-warning>#{escape(date)}</aside>)

      nil ->
        ""
    end
  end
end
