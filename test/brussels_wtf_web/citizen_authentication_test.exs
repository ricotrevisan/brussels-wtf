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
    first = post(recycle(conn), ~p"/citizen/magic-link/consume", %{"token" => token})
    assert redirected_to(first) == ~p"/citizen/registration"

    [cookie | _] =
      get_resp_header(first, "set-cookie")
      |> Enum.filter(&String.starts_with?(&1, "citizen_session="))

    assert cookie =~ "secure"
    assert cookie =~ "HttpOnly"
    assert cookie =~ "SameSite=Lax"
    assert post(recycle(conn), ~p"/citizen/magic-link/consume", %{"token" => token}).status == 422
  end

  test "magic link carries a fifteen-minute expiry", %{conn: conn} do
    post(conn, ~p"/citizen/magic-link", %{"email" => "expiry@example.test"})
    assert_receive {:magic_link, _, token, _}
    assert {:ok, %{"exp" => expires, "iat" => issued}} = Joken.peek_claims(token)
    assert expires - issued == 15 * 60
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

  test "local-follow import and collection claim are durable independent opt-ins" do
    configured = BrusselsWtf.Communes.configuration!("ixelles")

    BrusselsWtf.Ingestion.create_commune!(%{
      slug: "ixelles",
      name: configured.name,
      index_url: configured.index_url
    })

    Accounts.request_link("choices@example.test")
    assert_receive {:magic_link, _, token, _}
    {:ok, citizen, _session} = Accounts.consume(token)
    {:ok, collection, secret} = BrusselsWtf.Follow.create_collection()

    assert {:ok, [_]} =
             BrusselsWtf.Follow.import_citizen_follows(citizen, [{:commune, "ixelles"}])

    assert {:ok, untouched} = BrusselsWtf.Follow.view(collection.view_token)
    assert is_nil(untouched.owner_citizen_id)

    assert {:ok, claimed} = BrusselsWtf.Follow.claim_collection(secret, citizen)
    assert claimed.owner_citizen_id == citizen.id

    follows =
      BrusselsWtf.Follow.CitizenFollow
      |> Ash.read!(actor: %{id: citizen.id, principal: :citizen}, domain: BrusselsWtf.Follow)

    assert Enum.map(follows, &{&1.target_type, &1.target_identifier}) == [{:commune, "ixelles"}]
  end
end
