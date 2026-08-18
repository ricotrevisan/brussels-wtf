defmodule BrusselsWtfWeb.ReviewAuthenticationTest do
  use BrusselsWtfWeb.ConnCase, async: true

  test "anonymous readers are redirected away from the private review inbox", %{conn: conn} do
    conn = get(conn, ~p"/review")

    assert redirected_to(conn) == ~p"/review/login"
  end

  test "Rico can create a CSRF-protected session and sign out", %{conn: conn} do
    conn = get(conn, ~p"/review/login")

    csrf_token =
      conn.resp_body
      |> LazyHTML.from_fragment()
      |> then(&LazyHTML.attribute(&1["input[name='_csrf_token']"], "value"))
      |> List.first()

    conn =
      conn
      |> recycle()
      |> post(~p"/review/session", %{
        "_csrf_token" => csrf_token,
        "username" => "rico",
        "password" => "review-secret"
      })

    assert redirected_to(conn) == ~p"/review"

    conn = conn |> recycle() |> get(~p"/review")
    assert html_response(conn, 200) =~ "Review inbox"

    csrf_token = Plug.CSRFProtection.get_csrf_token()
    conn = conn |> recycle() |> delete(~p"/review/session", %{"_csrf_token" => csrf_token})
    assert redirected_to(conn) == ~p"/review/login"
  end

  test "invalid credentials do not create a review session", %{conn: conn} do
    conn = get(conn, ~p"/review/login")

    csrf_token =
      conn.resp_body
      |> LazyHTML.from_fragment()
      |> then(&LazyHTML.attribute(&1["input[name='_csrf_token']"], "value"))
      |> List.first()

    conn =
      conn
      |> recycle()
      |> post(~p"/review/session", %{
        "_csrf_token" => csrf_token,
        "username" => "rico",
        "password" => "wrong"
      })

    assert html_response(conn, 401) =~ "Invalid credentials"
    assert get(recycle(conn), ~p"/review") |> redirected_to() == ~p"/review/login"
  end

  test "expired and password-rotated sessions are rejected", %{conn: conn} do
    actor = %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}

    expired =
      conn
      |> init_test_session(%{})
      |> BrusselsWtfWeb.ReviewAuth.log_in(actor)
      |> put_session("review_authenticated_at", System.system_time(:second) - 28_801)
      |> get(~p"/review")

    assert redirected_to(expired) == ~p"/review/login"

    current_config = Application.fetch_env!(:brussels_wtf, :review_auth)
    valid = conn |> recycle() |> init_test_session(%{}) |> BrusselsWtfWeb.ReviewAuth.log_in(actor)

    Application.put_env(
      :brussels_wtf,
      :review_auth,
      Keyword.put(current_config, :password, "rotated-review-secret")
    )

    on_exit(fn -> Application.put_env(:brussels_wtf, :review_auth, current_config) end)

    assert valid |> get(~p"/review") |> redirected_to() == ~p"/review/login"
  end

  test "login rejects a request without a CSRF token", %{conn: conn} do
    conn = get(conn, ~p"/review/login")

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> recycle()
      |> then(&%{&1 | private: Map.delete(&1.private, :plug_skip_csrf_protection)})
      |> post(~p"/review/session", %{"username" => "rico", "password" => "review-secret"})
    end
  end
end
