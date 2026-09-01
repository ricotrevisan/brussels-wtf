defmodule BrusselsWtfWeb.CitizenSessionController do
  use BrusselsWtfWeb, :controller
  require Logger
  alias BrusselsWtf.Accounts

  @generic %{
    "fr" => "Si l’adresse est valide, un lien a été envoyé.",
    "nl" => "Als het adres geldig is, is een link verzonden.",
    "en" => "If the address is valid, a link has been sent."
  }
  @copy %{
    "fr" => %{
      title: "Compte citoyen",
      email: "Adresse e-mail",
      send: "Envoyer le lien de connexion",
      confirm: "Confirmation de la connexion…",
      invalid: "Ce lien est invalide ou expiré."
    },
    "nl" => %{
      title: "Burgeraccount",
      email: "E-mailadres",
      send: "Aanmeldlink versturen",
      confirm: "Aanmelding bevestigen…",
      invalid: "Deze link is ongeldig of verlopen."
    },
    "en" => %{
      title: "Citizen account",
      email: "Email",
      send: "Send magic link",
      confirm: "Confirming sign in…",
      invalid: "This link is invalid or expired."
    }
  }

  def new(conn, _) do
    copy = copy(conn)
    html(conn, page(conn, copy.title, form(copy)))
  end

  def create(conn, %{"email" => email}) do
    locale = locale(conn)
    :ok = Accounts.request_link(email, locale)
    html(conn, page(conn, copy(conn).title, Map.fetch!(@generic, locale)))
  end

  def create(conn, _), do: create(conn, %{"email" => ""})

  # The JWT is available to browser script only through the URL fragment. Fragments
  # are not sent in HTTP requests. Clear it before any network operation.
  def confirm(conn, _) do
    Logger.warning("citizen_magic_link_fragment_bootstrap")
    csrf = Plug.CSRFProtection.get_csrf_token()
    copy = copy(conn)

    script = """
    <p id="magic-link-status">#{copy.confirm}</p>
    <script>
    (() => {
      const fragment = location.hash;
      history.replaceState(null, '', location.pathname + location.search);
      const token = new URLSearchParams(fragment.slice(1)).get('token');
      if (!token) { document.getElementById('magic-link-status').textContent = #{Jason.encode!(copy.invalid)}; return; }
      fetch('/citizen/magic-link/consume', {
        method: 'POST', credentials: 'same-origin', redirect: 'follow',
        headers: {'x-csrf-token': #{Jason.encode!(csrf)}, 'x-citizen-magic-link': token}
      }).then(response => {
        if (response.ok) location.replace(response.url);
        else document.getElementById('magic-link-status').textContent = #{Jason.encode!(copy.invalid)};
      }).catch(() => document.getElementById('magic-link-status').textContent = #{Jason.encode!(copy.invalid)});
    })();
    </script>
    """

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> html(page(conn, copy.title, script))
  end

  def consume(conn, _) do
    token = conn |> get_req_header("x-citizen-magic-link") |> List.first()

    case Accounts.consume(token) do
      {:ok, _citizen, session} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:citizen_session_id, session.id)
        |> redirect(to: "/citizen/registration?lang=#{locale(conn)}")

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> html(page(conn, copy(conn).title, copy(conn).invalid))
    end
  end

  def delete(conn, _) do
    if id = get_session(conn, :citizen_session_id),
      do:
        BrusselsWtf.Accounts.Session
        |> Ash.get(
          id,
          actor: %{principal: :system},
          authorize?: true,
          domain: Accounts
        )
        |> (case do
              {:ok, s} ->
                Ash.destroy(s,
                  actor: %{principal: :system},
                  authorize?: true,
                  domain: Accounts
                )

              _ ->
                :ok
            end)

    conn
    |> delete_session(:citizen_session_id)
    |> redirect(to: ~p"/citizen/sign-in")
  end

  def registration(conn, _) do
    with {:ok, _} <- Accounts.authenticate_session(get_session(conn, :citizen_session_id)) do
      html(conn, page(conn, title(locale(conn)), registration_body(locale(conn))))
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> html(page(conn, title(locale(conn)), invalid(locale(conn))))
    end
  end

  def change_email(conn, %{"email" => email}) do
    with {:ok, citizen} <- Accounts.authenticate_session(get_session(conn, :citizen_session_id)),
         {:ok, _} <- Accounts.change_email(citizen, email) do
      conn
      |> configure_session(drop: true)
      |> redirect(to: ~p"/citizen/sign-in")
    else
      _ -> send_resp(conn, 401, "")
    end
  end

  def import_follows(conn, %{"targets" => targets}) when is_list(targets) do
    with {:ok, citizen} <- Accounts.authenticate_session(get_session(conn, :citizen_session_id)),
         parsed <- Enum.flat_map(targets, &parse_target/1),
         {:ok, imported} <- BrusselsWtf.Follow.import_citizen_follows(citizen, parsed) do
      choice(conn, :imported, length(imported))
    else
      _ -> send_resp(conn, 422, "")
    end
  end

  def import_follows(conn, _), do: choice(conn, :imported, 0)

  def claim_collection(conn, %{"management_secret" => secret}) do
    result =
      with {:ok, citizen} <-
             Accounts.authenticate_session(get_session(conn, :citizen_session_id)),
           do: BrusselsWtf.Follow.claim_collection(secret, citizen)

    choice(
      conn,
      if(match?({:ok, _}, result), do: :claimed, else: :invalid_collection),
      0
    )
  end

  def claim_collection(conn, _), do: choice(conn, :invalid_collection, 0)

  defp choice(conn, key, count) do
    with {:ok, _} <- Accounts.authenticate_session(get_session(conn, :citizen_session_id)) do
      messages = %{
        "fr" => %{
          imported: "Suivis locaux importés",
          claimed: "Collection revendiquée",
          invalid_collection: "Collection invalide"
        },
        "nl" => %{
          imported: "Lokale volgingen geïmporteerd",
          claimed: "Collectie geclaimd",
          invalid_collection: "Ongeldige collectie"
        },
        "en" => %{
          imported: "Local follows imported",
          claimed: "Collection claimed",
          invalid_collection: "Invalid collection"
        }
      }

      message = messages |> Map.fetch!(locale(conn)) |> Map.fetch!(key)

      html(
        conn,
        page(
          conn,
          title(locale(conn)),
          ~s(<p data-testid="citizen-choice-result" data-result="#{key}" data-count="#{count}">#{message}: #{count}</p>)
        )
      )
    else
      _ -> send_resp(conn, 401, "")
    end
  end

  defp parse_target(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [type, id] when type in ["dossier", "person", "legal_entity", "commune"] ->
        [{String.to_existing_atom(type), id}]

      _ ->
        []
    end
  end

  defp parse_target(_), do: []

  defp locale(conn), do: conn.assigns[:locale] || "en"
  defp copy(conn), do: Map.fetch!(@copy, locale(conn))
  defp title(locale), do: @copy |> Map.fetch!(locale) |> Map.fetch!(:title)
  defp invalid(locale), do: @copy |> Map.fetch!(locale) |> Map.fetch!(:invalid)

  defp form(copy) do
    token = Plug.CSRFProtection.get_csrf_token()

    ~s(<form method="post" action="/citizen/magic-link"><input type="hidden" name="_csrf_token" value="#{token}"><label>#{copy.email} <input name="email" type="email" required></label><button>#{copy.send}</button></form>)
  end

  defp registration_body("fr"),
    do:
      body(
        "fr",
        "Importer les suivis locaux sélectionnés",
        "Revendiquer séparément une collection anonyme"
      )

  defp registration_body("nl"),
    do:
      body(
        "nl",
        "Geselecteerde lokale volgingen importeren",
        "Een anonieme collectie afzonderlijk claimen"
      )

  defp registration_body(_),
    do: body("en", "Import selected local follows", "Separately claim an anonymous collection")

  defp management_label("fr"), do: "Secret de gestion"
  defp management_label("nl"), do: "Beheersleutel"
  defp management_label(_), do: "Management secret"

  defp body(locale, import, claim) do
    csrf = Plug.CSRFProtection.get_csrf_token()

    ~s"""
    <h2>#{import}</h2><form id="local-follow-import" method="post" action="/citizen/registration/import-follows"><input type="hidden" name="_csrf_token" value="#{csrf}"><fieldset id="local-follow-targets"><legend>#{import}</legend></fieldset><button>#{import}</button></form><h2>#{claim}</h2><form method="post" action="/citizen/registration/claim-collection"><input type="hidden" name="_csrf_token" value="#{csrf}"><label>#{management_label(locale)} <input name="management_secret"></label><button>#{claim}</button></form><script>try { const state=JSON.parse(localStorage.getItem('brussels.wtf:personal-feed:v1')||'{"follows":[]}'); const box=document.getElementById('local-follow-targets'); for (const target of (state.follows||[])) { if (!['dossier','person','legal_entity','commune'].includes(target.type)||!target.id) continue; const label=document.createElement('label'); const input=document.createElement('input'); input.type='checkbox'; input.name='targets[]'; input.value=target.type+':'+target.id; label.append(input,document.createTextNode(target.label||target.id)); box.append(label); }} catch (_) {}</script>
    """
  end

  defp page(conn, title, content) do
    "<!doctype html><html lang=\"" <>
      locale(conn) <>
      "\"><head><meta name=\"referrer\" content=\"no-referrer\"><title>" <>
      title <>
      "</title></head><body><main><h1>" <> title <> "</h1>" <> content <> "</main></body></html>"
  end
end
