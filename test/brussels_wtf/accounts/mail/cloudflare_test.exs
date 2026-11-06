defmodule BrusselsWtf.Accounts.Mail.CloudflareTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias BrusselsWtf.Accounts.Mail.{Cloudflare, Unconfigured}

  setup do
    previous = Application.get_env(:brussels_wtf, Cloudflare)

    Application.put_env(:brussels_wtf, Cloudflare,
      account_id: "acct123",
      api_token: "token-abc",
      from: "brussels.wtf <noreply@news.brussels.wtf>",
      req_options: [plug: {Req.Test, Cloudflare}]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:brussels_wtf, Cloudflare, previous),
        else: Application.delete_env(:brussels_wtf, Cloudflare)
    end)
  end

  defp accept(test_pid, result \\ %{"delivered" => ["reader@example.test"]}) do
    Req.Test.stub(Cloudflare, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn, Jason.decode!(raw)})
      Req.Test.json(conn, %{"success" => true, "result" => result})
    end)
  end

  test "sends a localized magic link with an absolute URL" do
    accept(self())

    link = "/citizen/magic-link?lang=nl#token=abc"
    assert :ok = Cloudflare.deliver_magic_link("reader@example.test", link, "nl")

    assert_receive {:request, conn, body}
    assert conn.method == "POST"
    assert conn.request_path == "/client/v4/accounts/acct123/email/sending/send"
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token-abc"]
    assert body["from"] == "brussels.wtf <noreply@news.brussels.wtf>"
    assert body["to"] == ["reader@example.test"]
    assert body["subject"] == "Uw aanmeldlink voor brussels.wtf"
    assert body["text"] =~ BrusselsWtfWeb.Endpoint.url() <> link
    assert body["text"] =~ "15 minuten"
  end

  test "sends the inactivity warning subject and body as given" do
    accept(self())

    assert :ok =
             Cloudflare.deliver_inactivity_warning(
               "reader@example.test",
               "fr",
               "Sujet",
               "Corps",
               DateTime.utc_now(),
               "key"
             )

    assert_receive {:request, _conn, %{"subject" => "Sujet", "text" => "Corps\n"}}
  end

  test "a bounced or suppressed recipient is a failure" do
    for list <- ["permanent_bounces", "suppressed_recipients"] do
      accept(self(), %{list => ["reader@example.test"]})

      log =
        capture_log(fn ->
          assert {:error, :recipient_rejected} =
                   Cloudflare.deliver_magic_link("reader@example.test", "/x", "en")
        end)

      refute log =~ "reader@example.test"
    end
  end

  test "an API error is a failure that does not log the recipient" do
    Req.Test.stub(Cloudflare, fn conn ->
      conn
      |> Plug.Conn.put_status(403)
      |> Req.Test.json(%{
        "success" => false,
        "errors" => [%{"code" => 10000, "message" => "Authentication error"}]
      })
    end)

    log =
      capture_log(fn ->
        assert {:error, {:http, 403, [%{"code" => 10000}]}} =
                 Cloudflare.deliver_magic_link("reader@example.test", "/x", "en")
      end)

    assert log =~ "citizen_mail_delivery_failed"
    refute log =~ "reader@example.test"
  end

  test "the unconfigured adapter fails every send" do
    capture_log(fn ->
      assert {:error, :mail_not_configured} = Unconfigured.deliver_magic_link("a@b.c", "/x", "en")

      assert {:error, :mail_not_configured} =
               Unconfigured.deliver_inactivity_warning("a@b.c", "en", "s", "b", nil, "k")
    end)
  end
end
