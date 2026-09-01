defmodule BrusselsWtfWeb.CitizenAuthenticationTest do
  use BrusselsWtfWeb.ConnCase, async: false
  import ExUnit.CaptureLog
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
    assert_receive {:magic_link, "new@example.test", token_link, "en"}
    token = token_from_link(token_link)

    first =
      recycle(conn)
      |> put_req_header("x-citizen-magic-link", token)
      |> post(~p"/citizen/magic-link/consume", %{})

    assert redirected_to(first) == "/citizen/registration?lang=en"

    [cookie | _] =
      get_resp_header(first, "set-cookie")
      |> Enum.filter(&String.starts_with?(&1, "_brussels_wtf_key="))

    assert cookie =~ "secure"
    assert cookie =~ "HttpOnly"
    assert cookie =~ "SameSite=Lax"

    replay =
      conn
      |> recycle()
      |> put_req_header("x-citizen-magic-link", token)
      |> post(~p"/citizen/magic-link/consume", %{})

    assert replay.status == 422
  end

  test "magic link carries a fifteen-minute expiry", %{conn: conn} do
    post(conn, ~p"/citizen/magic-link", %{"email" => "expiry@example.test"})
    assert_receive {:magic_link, _, token_link, _}
    token = token_from_link(token_link)
    assert {:ok, %{"exp" => expires, "iat" => issued}} = Joken.peek_claims(token)
    assert expires - issued == 15 * 60
  end

  test "idle, absolute, and email change revoke sessions", %{now: now} do
    Accounts.request_link("citizen@example.test")
    assert_receive {:magic_link, _, token_link, _}
    token = token_from_link(token_link)
    {:ok, _citizen, session} = Accounts.consume(token)
    Controlled.set(DateTime.add(now, 30, :day))
    assert {:error, :expired} = Accounts.authenticate_session(session.id)
    Controlled.set(now)
    Accounts.request_link("citizen@example.test")
    assert_receive {:magic_link, _, token2_link, _}
    token2 = token_from_link(token2_link)
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
    assert_receive {:magic_link, _, token_link, _}
    token = token_from_link(token_link)
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

  test "actual request and security-path logs redact citizen secrets", %{conn: conn} do
    email = "logger-secret@example.test"
    capability = "capability-do-not-log-123"

    logs =
      capture_log([level: :debug], fn ->
        request =
          post(conn, ~p"/citizen/magic-link", %{
            "email" => email,
            "management_secret" => capability
          })

        assert request.status == 200
        assert_receive {:magic_link, ^email, token_link, _}
        token = token_from_link(token_link)
        Process.put(:captured_raw_token, token)

        first_consume =
          conn
          |> recycle()
          |> put_req_header("x-citizen-magic-link", token)
          |> post(~p"/citizen/magic-link/consume", %{})

        assert first_consume.status == 302

        replay =
          conn
          |> recycle()
          |> put_req_header("x-citizen-magic-link", token)
          |> post(~p"/citizen/magic-link/consume", %{})

        assert replay.status == 422

        Accounts.request_link("change-log@example.test")
        assert_receive {:magic_link, _, change_token_link, _}
        change_token = token_from_link(change_token_link)
        {:ok, citizen, _} = Accounts.consume(change_token)
        assert {:ok, _} = Accounts.change_email(citizen, "changed-log@example.test")
        assert {:error, :not_found} = BrusselsWtf.Follow.exchange(capability)
      end)

    token = Process.get(:captured_raw_token)
    assert byte_size(logs) > 0

    for secret <- [
          email,
          token,
          capability,
          "change-log@example.test",
          "changed-log@example.test"
        ] do
      refute logs =~ secret
    end

    assert logs =~ "citizen_magic_link_requested"
    assert logs =~ "citizen_magic_link_rejected"
    assert logs =~ "citizen_email_changed_sessions_revoked"
    assert logs =~ "follow_collection_capability_checked"
  end

  test "absolute session boundary wins while idle activity is refreshed", %{now: now} do
    Accounts.request_link("absolute@example.test")
    assert_receive {:magic_link, _, token_link, _}
    token = token_from_link(token_link)
    {:ok, _, session} = Accounts.consume(token)

    for days <- [29, 58, 87] do
      Controlled.set(DateTime.add(now, days, :day))
      assert {:ok, _} = Accounts.authenticate_session(session.id)
    end

    Controlled.set(DateTime.add(now, 90, :day))
    assert {:error, :expired} = Accounts.authenticate_session(session.id)
  end

  test "email change revokes every concurrent session and outstanding old link" do
    Accounts.request_link("multi@example.test")
    assert_receive {:magic_link, _, first_link, _}
    first = token_from_link(first_link)
    {:ok, citizen, one} = Accounts.consume(first)
    Accounts.request_link("multi@example.test")
    assert_receive {:magic_link, _, second_link, _}
    second = token_from_link(second_link)
    {:ok, _, two} = Accounts.consume(second)
    Accounts.request_link("multi@example.test")
    assert_receive {:magic_link, _, outstanding_link, _}
    outstanding = token_from_link(outstanding_link)
    assert {:ok, _} = Accounts.change_email(citizen, "multi-changed@example.test")
    assert {:error, :expired} = Accounts.authenticate_session(one.id)
    assert {:error, :expired} = Accounts.authenticate_session(two.id)
    assert {:error, :invalid_or_expired} = Accounts.consume(outstanding)
  end

  test "existing new and unrelated email requests have identical public shape", %{conn: conn} do
    Accounts.request_link("existing@example.test")
    assert_receive {:magic_link, _, token_link, _}
    token = token_from_link(token_link)
    assert {:ok, _, _} = Accounts.consume(token)

    results =
      for email <- ["existing@example.test", "new-shape@example.test", "unrelated@example.test"] do
        response = post(recycle(conn), ~p"/citizen/magic-link", %{"email" => email})
        {response.status, response.resp_body}
      end

    assert Enum.uniq(results) |> length() == 1

    for {_, body} <- results do
      refute body =~ "existing@example.test"
      refute body =~ "new-shape@example.test"
      refute body =~ "unrelated@example.test"
    end
  end

  test "valid citizen session is denied every editor route", %{conn: conn} do
    Accounts.request_link("route-denial@example.test")
    assert_receive {:magic_link, _, token_link, _}
    token = token_from_link(token_link)
    {:ok, _, session} = Accounts.consume(token)

    routes =
      BrusselsWtfWeb.Router.__routes__()
      |> Enum.filter(&String.starts_with?(&1.path, "/review"))
      |> Enum.reject(&(&1.path in ["/review/login", "/review/session"]))

    assert routes != []

    for route <- routes do
      path = Regex.replace(~r/:\w+/, route.path, "00000000-0000-0000-0000-000000000000")

      request =
        conn
        |> recycle()
        |> init_test_session(%{citizen_session_id: session.id})
        |> dispatch(BrusselsWtfWeb.Endpoint, route.verb, path, %{})

      refute request.status in 200..299
      assert get_session(request, :citizen_session_id) == session.id
    end
  end

  test "claim action rejects another citizen id and reassignment at the Ash boundary" do
    Accounts.request_link("boundary@example.test")
    assert_receive {:magic_link, _, link, _}
    {:ok, citizen, _} = Accounts.consume(token_from_link(link))
    {:ok, collection, _} = BrusselsWtf.Follow.create_collection()
    actor = %{id: citizen.id, principal: :citizen}
    other = Ash.UUID.generate()

    assert {:error, _} =
             collection
             |> Ash.Changeset.for_update(:claim, %{owner_citizen_id: other})
             |> Ash.update(actor: actor, authorize?: true, domain: BrusselsWtf.Follow)

    assert {:ok, claimed} =
             collection
             |> Ash.Changeset.for_update(:claim, %{owner_citizen_id: citizen.id})
             |> Ash.update(actor: actor, authorize?: true, domain: BrusselsWtf.Follow)

    assert {:error, _} =
             claimed
             |> Ash.Changeset.for_update(:claim, %{owner_citizen_id: citizen.id})
             |> Ash.update(actor: actor, authorize?: true, domain: BrusselsWtf.Follow)
  end

  defp token_from_link(link) do
    link |> URI.parse() |> Map.fetch!(:fragment) |> URI.decode_query() |> Map.fetch!("token")
  end
end
