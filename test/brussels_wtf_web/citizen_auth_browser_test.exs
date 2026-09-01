defmodule BrusselsWtfWeb.CitizenAuthBrowserTest do
  use BrusselsWtf.DataCase, async: false
  @moduletag :browser
  @port 4103
  test "real Chromium uses one isolated magic link and sees independent opt-ins" do
    Ecto.Adapters.SQL.Sandbox.mode(BrusselsWtf.Repo, {:shared, self()})
    mail = Path.join(System.tmp_dir!(), "citizen-mail-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:brussels_wtf, :citizen_mailer)
    Application.put_env(:brussels_wtf, :citizen_mailer, BrusselsWtf.Accounts.Mail.Memory)
    Process.register(self(), BrusselsWtf.Accounts.Mailbox)
    :ok = BrusselsWtf.Accounts.request_link("expired-browser@example.test")
    assert_receive {:magic_link, _, issued, _}
    {:ok, claims} = Joken.peek_claims(issued)
    past = System.system_time(:second) - 60
    expired_claims = claims |> Map.put("iat", past - 15 * 60) |> Map.put("exp", past)

    signer =
      Joken.Signer.create(
        "HS256",
        Application.fetch_env!(:brussels_wtf, :citizen_token_signing_secret)
      )

    {:ok, expired, _} = Joken.encode_and_sign(expired_claims, signer)
    expired_file = mail <> ".expired"
    File.write!(expired_file, expired)
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
      expired_file
    ]

    opts =
      [stderr_to_stdout: true] ++
        case System.get_env("PLAYWRIGHT_CHROMIUM_EXECUTABLE") do
          nil -> []
          executable -> [env: [{"PLAYWRIGHT_CHROMIUM_EXECUTABLE", executable}]]
        end

    {output, status} = System.cmd("uv", args, opts)
    assert status == 0, output
  end
end
