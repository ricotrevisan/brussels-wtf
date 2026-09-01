defmodule BrusselsWtfWeb.CitizenAuthBrowserTest do
  use BrusselsWtf.DataCase, async: false
  import ExUnit.CaptureLog, only: [capture_log: 2]
  @moduletag :browser
  @port 4103
  test "real Chromium uses one isolated magic link and sees independent opt-ins" do
    Ecto.Adapters.SQL.Sandbox.mode(BrusselsWtf.Repo, {:shared, self()})
    configured = BrusselsWtf.Communes.configuration!("ixelles")

    BrusselsWtf.Ingestion.create_commune!(%{
      slug: "ixelles",
      name: configured.name,
      index_url: configured.index_url
    })

    {:ok, collection, management_secret} = BrusselsWtf.Follow.create_collection()
    mail = Path.join(System.tmp_dir!(), "citizen-mail-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:brussels_wtf, :citizen_mailer)
    Application.put_env(:brussels_wtf, :citizen_mailer, BrusselsWtf.Accounts.Mail.Memory)
    Process.register(self(), BrusselsWtf.Accounts.Mailbox)
    :ok = BrusselsWtf.Accounts.request_link("expired-browser@example.test")
    assert_receive {:magic_link, _, issued_link, _}

    issued =
      issued_link
      |> URI.parse()
      |> Map.fetch!(:fragment)
      |> URI.decode_query()
      |> Map.fetch!("token")

    {:ok, claims} = Joken.peek_claims(issued)

    assert {:ok, %BrusselsWtf.Accounts.Token{jti: stored_jti, purpose: stored_purpose}} =
             BrusselsWtf.Accounts.Token
             |> Ash.Query.for_read(:get_token, %{jti: claims["jti"], purpose: "magic_link"})
             |> Ash.read_one(authorize?: false, domain: BrusselsWtf.Accounts)

    assert stored_jti == claims["jti"]
    assert stored_purpose == "magic_link"

    past = System.system_time(:second) - 60
    expired_claims = claims |> Map.put("iat", past - 15 * 60) |> Map.put("exp", past)

    signer =
      Joken.Signer.create(
        "HS256",
        Application.fetch_env!(:brussels_wtf, :citizen_token_signing_secret)
      )

    {:ok, expired, _} = Joken.encode_and_sign(expired_claims, signer)
    expired_file = mail <> ".expired"
    File.write!(expired_file, "/citizen/magic-link?lang=en#token=#{URI.encode_www_form(expired)}")
    Process.unregister(BrusselsWtf.Accounts.Mailbox)
    Application.put_env(:brussels_wtf, :citizen_mailer, BrusselsWtf.Accounts.Mail.File)
    Application.put_env(:brussels_wtf, :citizen_mail_file, mail)

    {:ok, server} =
      Bandit.start_link(plug: BrusselsWtfWeb.Endpoint, port: @port, ip: {127, 0, 0, 1})

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :citizen_mailer, previous)
      Application.delete_env(:brussels_wtf, :citizen_mail_file)
      File.rm(mail)
      File.rm(expired_file)
      if Process.alive?(server), do: Process.exit(server, :normal)
    end)

    args = [
      "run",
      "--project",
      "test/browser",
      "--frozen",
      "python",
      "test/browser/citizen_auth.py",
      "--base",
      "http://127.0.0.1:#{@port}",
      "--mail",
      mail,
      "--expired",
      expired_file,
      "--secret",
      management_secret
    ]

    opts =
      [stderr_to_stdout: true] ++
        case System.get_env("PLAYWRIGHT_CHROMIUM_EXECUTABLE") do
          nil -> []
          executable -> [env: [{"PLAYWRIGHT_CHROMIUM_EXECUTABLE", executable}]]
        end

    {logs, {output, status}} =
      with_log(fn -> System.cmd("uv", args, opts) end)

    assert status == 0, output

    for secret <- [
          issued,
          expired,
          "expired-browser@example.test",
          "browser@example.test",
          "outstanding-magic-link:expired-browser@example.test",
          management_secret
        ] do
      refute logs =~ secret
      refute output =~ secret
    end

    refute logs =~ "#token="
    refute output =~ "#token="
    assert logs =~ "citizen_magic_link_fragment_bootstrap"
    assert logs =~ "citizen_magic_link_consumed"
    assert logs =~ "citizen_magic_link_rejected"

    assert [%{target_type: :commune, target_identifier: "ixelles"}] =
             Ash.read!(BrusselsWtf.Follow.CitizenFollow,
               authorize?: false,
               domain: BrusselsWtf.Follow
             )

    assert {:ok, %{owner_citizen_id: owner}} = BrusselsWtf.Follow.view(collection.view_token)
    assert is_binary(owner)
  end

  defp with_log(fun) do
    parent = self()
    ref = make_ref()

    logs =
      capture_log([level: :debug], fn ->
        send(parent, {ref, fun.()})
      end)

    receive do
      {^ref, result} -> {logs, result}
    end
  end
end
