defmodule BrusselsWtf.ProviderCreditTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Alerts.Drummer
  alias BrusselsWtf.Council
  alias BrusselsWtf.ProviderCredit

  @secret "drummer-test-secret"

  setup do
    keys = [:coverage_generation, :coverage_processor, Drummer, :provider_credit_low_cents]
    previous = Map.new(keys, &{&1, Application.fetch_env(:brussels_wtf, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, config} -> Application.put_env(:brussels_wtf, key, config)
          :error -> Application.delete_env(:brussels_wtf, key)
        end
      end
    end)

    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :paid,
      backfill_enabled: false,
      monthly_budget_cents: nil
    })

    Application.put_env(
      :brussels_wtf,
      :coverage_processor,
      BrusselsWtf.Processors.OpenRouterCoverage
    )

    Application.put_env(:brussels_wtf, :provider_credit_low_cents, 500)

    Application.put_env(:brussels_wtf, Drummer,
      url: "http://drummer.test/webhooks/brussels-wtf-alerts",
      secret: @secret,
      req_options: [plug: {Req.Test, Drummer}]
    )

    owner = self()

    Req.Test.stub(Drummer, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [timestamp] = Plug.Conn.get_req_header(conn, "x-webhook-timestamp")
      [signature] = Plug.Conn.get_req_header(conn, "x-webhook-signature-v2")

      expected =
        :crypto.mac(:hmac, :sha256, @secret, timestamp <> "." <> body)
        |> Base.encode16(case: :lower)

      assert signature == expected
      assert [_id] = Plug.Conn.get_req_header(conn, "x-request-id")
      send(owner, {:alert, Jason.decode!(body)["message"]})
      Req.Test.json(conn, %{"status" => "delivered"})
    end)

    :ok
  end

  defp balance(account, key \\ nil),
    do: {:ok, %{account_remaining_cents: account, key_remaining_cents: key}}

  defp alerts(acc \\ []) do
    receive do
      {:alert, message} -> alerts([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a healthy balance records a check and alerts nobody" do
    assert {:ok, check} = ProviderCredit.check("scheduled", balance: balance(4_999, 4_955))
    assert {check.level, check.notified_level} == {:ok, :ok}
    assert alerts() == []
  end

  test "low credit alerts once, the lowest of key and account counts, and recovery alerts once" do
    assert {:ok, %{level: :low}} = ProviderCredit.check("scheduled", balance: balance(9_000, 420))
    assert [message] = alerts()
    assert message =~ "OpenRouter credit is low, $4.20 left"
    assert message =~ "API key limit $4.20"

    assert {:ok, %{level: :low}} = ProviderCredit.check("scheduled", balance: balance(9_000, 400))
    assert alerts() == []

    assert {:ok, %{level: :ok}} = ProviderCredit.check("scheduled", balance: balance(9_000))
    assert [back] = alerts()
    assert back =~ "credit is back, $90.00 left"
  end

  test "a failed alert is retried by the next check" do
    Req.Test.stub(Drummer, fn conn -> Plug.Conn.send_resp(conn, 502, "down") end)

    assert {:ok, %{level: :low, notified_level: :ok}} =
             ProviderCredit.check("scheduled", balance: balance(100))

    owner = self()

    Req.Test.stub(Drummer, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:alert, Jason.decode!(body)["message"]})
      Req.Test.json(conn, %{})
    end)

    assert {:ok, %{notified_level: :low}} =
             ProviderCredit.check("scheduled", balance: balance(90))

    assert [_message] = alerts()
  end

  test "an unreachable balance endpoint records the check without an alert" do
    assert {:ok, %{level: :unavailable, notified_level: :ok}} =
             ProviderCredit.check("scheduled", balance: {:error, :credit_balance_unavailable})

    assert alerts() == []
  end

  test "a 402 is exhaustion, and returning credit resumes every stranded page" do
    BrusselsWtf.Seeds.PublicTimeline.run!()
    meeting = Council.get_ingested_meeting!("ixelles", "demo-ixelles")
    page = meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)

    BrusselsWtf.Review.open_review_case!(%{
      kind: :publication,
      commune_id: meeting.commune_id,
      affected_record_id: page.id,
      affected_record_type: "meeting_page",
      processing_generation: "sha256:test:credit",
      urgency: :high,
      summary: "Coverage provider is out of credit; publishing resumes when credit returns",
      diagnostics: %{"classification" => "provider_credit_exhausted"}
    })

    assert ProviderCredit.stranded_meeting_ids() == [meeting.id]

    assert {:ok, %{level: :exhausted, resumed_pages: 0}} =
             ProviderCredit.check("payment_required", balance: balance(2_000))

    assert [message] = alerts()
    assert message =~ "out of credit"
    assert message =~ "1 meeting page waiting"
    refute_enqueued worker: BrusselsWtf.Workers.PublishMeeting

    assert {:ok, %{level: :ok, resumed_pages: 1}} =
             ProviderCredit.check("scheduled", balance: balance(2_000))

    assert_enqueued worker: BrusselsWtf.Workers.PublishMeeting,
                    args: %{"meeting_id" => meeting.id}

    assert [resumed] = alerts()
    assert resumed =~ "Resuming 1 meeting page."
  end

  test "outside paid OpenRouter generation the check does nothing" do
    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :recorded,
      backfill_enabled: false,
      monthly_budget_cents: nil
    })

    assert ProviderCredit.check("scheduled", balance: balance(0)) == :skipped
    assert alerts() == []
  end

  test "without Drummer configuration an alert is not sent and is retried later" do
    Application.put_env(:brussels_wtf, Drummer, [])
    assert {:error, :alert_not_configured} = Drummer.notify("hello", "id-1")
  end
end
