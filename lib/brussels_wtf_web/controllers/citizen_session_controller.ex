defmodule BrusselsWtfWeb.CitizenSessionController do
  use BrusselsWtfWeb, :controller
  alias BrusselsWtf.Accounts

  @generic %{
    "fr" => "Si l’adresse est valide, un lien a été envoyé.",
    "nl" => "Als het adres geldig is, is een link verzonden.",
    "en" => "If the address is valid, a link has been sent."
  }
  def new(conn, _), do: html(conn, page(conn, "Citizen sign in", form()))

  def create(conn, %{"email" => email}) do
    locale = locale(conn)
    :ok = Accounts.request_link(email, locale)
    html(conn, page(conn, title(locale), Map.fetch!(@generic, locale)))
  end

  def create(conn, _), do: create(conn, %{"email" => ""})

  def consume(conn, %{"token" => token}) do
    case Accounts.consume(token) do
      {:ok, _citizen, session} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:citizen_session_id, session.id)
        |> put_resp_cookie("citizen_session", session.id,
          secure: true,
          http_only: true,
          same_site: "Lax",
          max_age: 7_776_000
        )
        |> redirect(to: ~p"/citizen/registration")

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> html(page(conn, title(locale(conn)), invalid(locale(conn))))
    end
  end

  def delete(conn, _) do
    if id = get_session(conn, :citizen_session_id),
      do:
        BrusselsWtf.Accounts.Session
        |> Ash.get(id, authorize?: false, domain: Accounts)
        |> (case do
              {:ok, s} -> Ash.destroy(s, authorize?: false, domain: Accounts)
              _ -> :ok
            end)

    conn
    |> delete_session(:citizen_session_id)
    |> delete_resp_cookie("citizen_session", secure: true, http_only: true, same_site: "Lax")
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
      |> delete_resp_cookie("citizen_session", secure: true, http_only: true, same_site: "Lax")
      |> redirect(to: ~p"/citizen/sign-in")
    else
      _ -> send_resp(conn, 401, "")
    end
  end

  def import_follows(conn, %{"targets" => targets}) when is_list(targets),
    do: choice(conn, "local follows imported", length(targets))

  def import_follows(conn, _), do: choice(conn, "local follows imported", 0)

  def claim_collection(conn, %{"management_secret" => secret}) do
    result = BrusselsWtf.Follow.exchange(secret)

    choice(
      conn,
      if(match?({:ok, _}, result), do: "collection claimed", else: "invalid collection"),
      0
    )
  end

  def claim_collection(conn, _), do: choice(conn, "invalid collection", 0)

  defp choice(conn, message, count) do
    with {:ok, _} <- Accounts.authenticate_session(get_session(conn, :citizen_session_id)) do
      html(conn, page(conn, title(locale(conn)), "<p>#{message}: #{count}</p>"))
    else
      _ -> send_resp(conn, 401, "")
    end
  end

  defp locale(conn), do: conn.assigns[:locale] || "en"
  defp title("fr"), do: "Compte citoyen"
  defp title("nl"), do: "Burgeraccount"
  defp title(_), do: "Citizen account"
  defp invalid("fr"), do: "Ce lien est invalide ou expiré."
  defp invalid("nl"), do: "Deze link is ongeldig of verlopen."
  defp invalid(_), do: "This link is invalid or expired."

  defp form do
    token = Plug.CSRFProtection.get_csrf_token()

    ~s(<form method="post" action="/citizen/magic-link"><input type="hidden" name="_csrf_token" value="#{token}"><label>Email <input name="email" type="email" required></label><button>Send magic link</button></form>)
  end

  defp registration_body("fr"),
    do:
      body(
        "Importer les suivis locaux sélectionnés",
        "Revendiquer séparément une collection anonyme"
      )

  defp registration_body("nl"),
    do:
      body(
        "Geselecteerde lokale volgingen importeren",
        "Een anonieme collectie afzonderlijk claimen"
      )

  defp registration_body(_),
    do: body("Import selected local follows", "Separately claim an anonymous collection")

  defp body(import, claim),
    do:
      ~s(<h2>#{import}</h2><form method="post" action="/citizen/registration/import-follows"><button>#{import}</button></form><h2>#{claim}</h2><form method="post" action="/citizen/registration/claim-collection"><input name="management_secret"><button>#{claim}</button></form>)

  defp page(conn, title, content) do
    "<!doctype html><html lang=\"" <>
      locale(conn) <>
      "\"><head><meta name=\"referrer\" content=\"no-referrer\"><title>" <>
      title <>
      "</title></head><body><main><h1>" <> title <> "</h1>" <> content <> "</main></body></html>"
  end
end
