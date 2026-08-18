defmodule BrusselsWtfWeb.ReviewSessionController do
  use BrusselsWtfWeb, :controller

  def new(conn, _params), do: render_login(conn, nil, 200)

  def create(conn, %{"username" => username, "password" => password}) do
    case BrusselsWtfWeb.ReviewAuth.authenticate(username, password) do
      {:ok, actor} ->
        conn
        |> BrusselsWtfWeb.ReviewAuth.log_in(actor)
        |> redirect(to: ~p"/review")

      {:error, :invalid_credentials} ->
        render_login(conn, "Invalid credentials", 401)
    end
  end

  def create(conn, _params), do: render_login(conn, "Invalid credentials", 401)

  def delete(conn, _params) do
    conn
    |> BrusselsWtfWeb.ReviewAuth.log_out()
    |> redirect(to: ~p"/review/login")
  end

  defp render_login(conn, error, status) do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> put_status(status)
    |> html("""
    <!doctype html>
    <html lang="en">
      <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Review sign in · brussels.wtf</title></head>
      <body>
        <main style="max-width:32rem;margin:4rem auto;padding:1rem;font-family:system-ui">
          <h1>Review sign in</h1>
          #{if error, do: ~s(<p role="alert">#{error |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()}</p>), else: ""}
          <form method="post" action="/review/session">
            <input type="hidden" name="_csrf_token" value="#{csrf_token}">
            <p><label>Username <input name="username" autocomplete="username" required></label></p>
            <p><label>Password <input type="password" name="password" autocomplete="current-password" required></label></p>
            <button type="submit">Sign in</button>
          </form>
        </main>
      </body>
    </html>
    """)
  end
end
