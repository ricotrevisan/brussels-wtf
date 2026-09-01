defmodule BrusselsWtfWeb.CitizenAuthenticationTest do
  use BrusselsWtfWeb.ConnCase, async: false
  alias BrusselsWtf.{Accounts, Clock.Controlled}

  setup do
    Process.register(self(), BrusselsWtf.Accounts.Mailbox)
    now = ~U[2026-09-02 12:00:00.000000Z]
    Controlled.set(now)

    on_exit(fn ->
      if Process.whereis(BrusselsWtf.Accounts.Mailbox) == self(),
        do: Process.unregister(BrusselsWtf.Accounts.Mailbox)
    end)

    %{now: now}
  end

  test "request is enumeration resistant and link is single use", %{conn: conn} do
    body =
      conn
      |> post(~p"/citizen/magic-link", %{"email" => "new@example.test"})
      |> html_response(200)

    assert body =~ "If the address is valid"
    refute body =~ "new@example.test"
    assert_receive {:magic_link, "new@example.test", token, "en"}
    first = get(recycle(conn), ~p"/citizen/magic-link?token=#{token}")
    assert redirected_to(first) == ~p"/citizen/registration"

    [cookie | _] =
      get_resp_header(first, "set-cookie")
      |> Enum.filter(&String.starts_with?(&1, "citizen_session="))

    assert cookie =~ "secure"
    assert cookie =~ "HttpOnly"
    assert cookie =~ "SameSite=Lax"
    assert get(recycle(conn), ~p"/citizen/magic-link?token=#{token}").status == 422
  end

  test "link expires at fifteen minutes", %{conn: conn, now: now} do
    post(conn, ~p"/citizen/magic-link", %{"email" => "expiry@example.test"})
    assert_receive {:magic_link, _, token, _}
    Controlled.set(DateTime.add(now, 15, :minute))
    assert get(recycle(conn), ~p"/citizen/magic-link?token=#{token}").status == 422
  end

  test "idle, absolute, and email change revoke sessions", %{now: now} do
    Accounts.request_link("citizen@example.test")
    assert_receive {:magic_link, _, token, _}
    {:ok, _citizen, session} = Accounts.consume(token)
    Controlled.set(DateTime.add(now, 30, :day))
    assert {:error, :expired} = Accounts.authenticate_session(session.id)
    Controlled.set(now)
    Accounts.request_link("citizen@example.test")
    assert_receive {:magic_link, _, token2, _}
    {:ok, citizen, session2} = Accounts.consume(token2)
    assert {:ok, _} = Accounts.change_email(citizen, "changed@example.test")
    assert {:error, :expired} = Accounts.authenticate_session(session2.id)
  end
end
