defmodule BrusselsWtf.Processors.OpenCodeCoverageTest do
  use ExUnit.Case, async: false
  alias BrusselsWtf.Processors.OpenCodeCoverage, as: Provider
  @models ["qwen3.8-max", "deepseek-v4.1-flash"]
  @primary hd(@models)
  @fallback List.last(@models)

  setup do
    old = Application.get_env(:brussels_wtf, Provider)

    Application.put_env(:brussels_wtf, Provider,
      api_key: "secret-test-key",
      plug: {Req.Test, Provider}
    )

    on_exit(fn ->
      if old,
        do: Application.put_env(:brussels_wtf, Provider, old),
        else: Application.delete_env(:brussels_wtf, Provider)
    end)

    :ok
  end

  test "metadata declares paid network use and the pinned ordered chain" do
    metadata = Provider.metadata()
    assert metadata.billing_mode == :paid
    assert metadata.network_access == :network
    assert metadata.provider_category == "opencode"
    assert metadata.model == Enum.join(@models, " -> ")
    assert metadata.allowed_models == @models
    # 32 cents for the capped Qwen request plus 6 for the capped DeepSeek request.
    assert {:ok, 38} = Provider.maximum_cost(:canonical_generation, %{})
    assert {:ok, 38} = Provider.maximum_cost(:translation, %{})
    hash = metadata.config_hash
    Application.put_env(:brussels_wtf, Provider, api_key: "different-secret")
    assert Provider.metadata().config_hash == hash
    refute inspect(metadata) =~ "secret"
  end

  test "primary request carries fixed caps and settles cost from token counts" do
    parent = self()

    Req.Test.expect(Provider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, Jason.decode!(body)})
      assert conn.request_path == "/inference/openai/v1/chat/completions"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret-test-key"]
      assert Plug.Conn.get_req_header(conn, "user-agent") == ["brussels-wtf-coverage/1"]
      Req.Test.json(conn, response(bundle()))
    end)

    assert {:ok, output, usage} = Provider.generate_fr(input())
    assert output == bundle()

    assert Map.drop(usage, ["stages"]) == %{
             "network_calls" => 1,
             "model" => @primary,
             "input_tokens" => 5_000,
             "output_tokens" => 2_000,
             # 5,000 x $2/M + 2,000 x $6/M = 2.2 cents, rounded up.
             "cost_cents" => 3,
             "response_id" => "chatcmpl-example",
             "response_model" => "qwen3.8-max-2026"
           }

    assert_received {:request, body}
    assert body["model"] == @primary
    assert hd(body["messages"])["content"] =~ "does NOT establish adoption"
    assert hd(body["messages"])["content"] =~ "not yet adopted"
    assert body["max_tokens"] == 8_192
    assert body["stream"] == false
    assert body["temperature"] == 0
    assert body["response_format"] == %{"type" => "json_object"}
    refute Map.has_key?(body, "tools")
    refute Map.has_key?(body, "models")
    assert Jason.decode!(List.last(body["messages"])["content"]) == input()
  end

  test "retryable failure advances once to the fallback with an otherwise identical request" do
    parent = self()

    Req.Test.expect(Provider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:primary, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => %{"type" => "rate_limit", "message" => "Rate limited"}})
    end)

    Req.Test.expect(Provider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:fallback, Jason.decode!(body)})
      Req.Test.json(conn, response(bundle(), "deepseek-v4.1-flash"))
    end)

    assert {:ok, _, usage} = Provider.generate_fr(input())
    assert_received {:primary, primary}
    assert_received {:fallback, fallback}
    assert primary["model"] == @primary
    assert fallback["model"] == @fallback
    assert Map.delete(fallback, "model") == Map.delete(primary, "model")
    assert usage["model"] == @fallback
    assert usage["network_calls"] == 2
    # The failed stage reports no tokens, so the operation's cost stays unknown.
    refute Map.has_key?(usage, "cost_cents")
    assert [first, second] = usage["stages"]

    assert first == %{
             "status" => "provider_http_error",
             "http_status" => 429,
             "network_calls" => 1,
             "model" => @primary
           }

    assert second["status"] == "ok"
    # 5,000 x $0.30/M + 2,000 x $1.20/M = 0.39 cents, rounded up.
    assert second["cost_cents"] == 1
  end

  test "retryable failures stop after the last model and retain safe stage receipts" do
    for status <- [408, 429, 500, 503] do
      Req.Test.expect(Provider, 2, fn conn ->
        Plug.Conn.send_resp(conn, status, "secret-test-key private prompt")
      end)

      assert {:error, {:provider_http_error, %{http_status: ^status}}, usage} =
               result = Provider.generate_fr(input())

      assert usage["network_calls"] == 2
      assert usage["model"] == @fallback
      assert Enum.map(usage["stages"], & &1["model"]) == @models
      refute Map.has_key?(usage, "cost_cents")
      refute inspect(result) =~ "secret-test-key"
      refute inspect(result) =~ "private prompt"
    end
  end

  test "budget, credit, auth and request errors never advance the chain" do
    for {status, body} <- [
          {429,
           %{
             "error" => %{
               "type" => "server_error",
               "message" => "Upstream request failed: Account budget exceeded"
             }
           }},
          {402,
           %{
             "error" => %{
               "type" => "server_error",
               "message" => "Upstream request failed: Insufficient account funds"
             }
           }},
          {403, %{"type" => "error", "error" => %{"type" => "FreeTierError", "message" => "x"}}},
          {401, %{"_tag" => "Unauthorized"}},
          {400, %{"error" => %{"message" => "secret-test-key private prompt"}}},
          {404, %{"error" => %{"message" => "Model not found"}}}
        ] do
      Req.Test.expect(Provider, fn conn ->
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end)

      assert {:error, {:provider_http_error, %{http_status: ^status, retryable: false}}, usage} =
               result = Provider.generate_fr(input())

      assert usage["network_calls"] == 1
      refute Map.has_key?(usage, "cost_cents")
      refute inspect(result) =~ "secret-test-key"
      refute inspect(result) =~ "private prompt"
    end
  end

  test "missing or malformed token counts leave cost unknown" do
    for raw <- [
          nil,
          %{"prompt_tokens" => 10},
          %{"prompt_tokens" => -1, "completion_tokens" => 1},
          %{"prompt_tokens" => "10", "completion_tokens" => 1}
        ] do
      Req.Test.expect(Provider, fn conn ->
        Req.Test.json(conn, Map.put(response(bundle()), "usage", raw))
      end)

      assert {:ok, _, usage} = Provider.generate_fr(input())
      assert usage["model"] == @primary
      refute Map.has_key?(usage, "cost_cents")
      refute Map.has_key?(usage, "input_tokens")
    end
  end

  test "known costs from every stage are summed and a zero-token answer costs nothing" do
    Req.Test.expect(Provider, fn conn ->
      conn |> Plug.Conn.put_status(503) |> Req.Test.json(response(bundle()))
    end)

    Req.Test.expect(Provider, fn conn ->
      Req.Test.json(conn, response(bundle(), "deepseek", {0, 0}))
    end)

    assert {:ok, _, usage} = Provider.translate(bundle(), "en")
    # HTTP error stages never carry usage, even when the body resembles a response.
    refute Map.has_key?(usage, "cost_cents")

    Req.Test.expect(Provider, fn conn ->
      Req.Test.json(conn, response(bundle(), "qwen", {0, 0}))
    end)

    assert {:ok, _, %{"cost_cents" => 0}} = Provider.translate(bundle(), "nl")

    Req.Test.expect(Provider, fn conn ->
      Req.Test.json(conn, response(bundle(), "qwen", {1_000_000, 1}))
    end)

    assert {:ok, _, %{"cost_cents" => 201}} = Provider.translate(bundle(), "nl")
  end

  test "primary stage timeout advances once and keeps the cancelled cost unknown" do
    parent = self()

    Req.Test.expect(Provider, fn conn ->
      send(parent, {:waiting_primary, self()})

      receive do
        :never -> conn
      end
    end)

    Req.Test.expect(Provider, fn conn ->
      Req.Test.json(conn, response(bundle(), "deepseek"))
    end)

    started = System.monotonic_time(:millisecond)
    assert {:ok, _, usage} = Provider.generate_fr(input())
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 45_000 and elapsed < 50_000
    assert_received {:waiting_primary, pid}
    refute Process.alive?(pid)
    assert usage["network_calls"] == 2
    assert hd(usage["stages"])["status"] == "provider_wall_timeout"
    assert hd(usage["stages"])["model"] == @primary
    refute Map.has_key?(usage, "cost_cents")
  end

  test "configuration cannot override request limits" do
    Application.put_env(:brussels_wtf, Provider,
      api_key: "secret-test-key",
      plug: {Req.Test, Provider},
      req_options: [
        receive_timeout: 999_999,
        retry: true,
        redirect: true,
        url: "https://evil.example",
        json: %{"max_tokens" => 99_999}
      ]
    )

    Req.Test.expect(Provider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert conn.host == "opencode.ai"
      data = Jason.decode!(body)
      assert data["max_tokens"] == 8_192
      assert data["model"] == @primary
      Req.Test.json(conn, response(bundle()))
    end)

    assert {:ok, _, _} = Provider.generate_fr(input())
  end

  test "missing key, oversized input and private extra keys make no network call" do
    Req.Test.stub(Provider, fn _ -> flunk("unexpected provider request") end)

    assert {:error, :input_too_large, %{"cost_cents" => 0}} =
             Provider.generate_fr(
               put_in(input(), ["meeting_identifier"], String.duplicate("a", 66_000))
             )

    assert {:error, :invalid_publication_input, _} =
             Provider.generate_fr(Map.put(input(), "private_object_key", "private"))

    Application.put_env(:brussels_wtf, Provider, api_key: nil)
    assert {:error, :missing_api_key, %{"network_calls" => 0}} = Provider.generate_fr(input())

    for key <- ["op://Dev/Opencode/brussels-wtf", " padded", ""] do
      Application.put_env(:brussels_wtf, Provider, api_key: key)
      assert {:error, :missing_api_key, _} = Provider.generate_fr(input())
      assert_raise ArgumentError, fn -> Provider.validate_configuration!() end
    end
  end

  test "redirects are sanitized and never followed" do
    Req.Test.expect(Provider, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://evil.example")
      |> Plug.Conn.send_resp(302, "secret-test-key private prompt")
    end)

    assert {:error, {:provider_http_error, %{http_status: 302, retryable: false}}, usage} =
             result = Provider.generate_fr(input())

    assert usage["network_calls"] == 1
    refute inspect(result) =~ "secret-test-key"
  end

  test "malformed responses fail closed without advancing" do
    for body <- ["not json", "[]"] do
      Req.Test.expect(Provider, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)

      assert {:error, :invalid_provider_response, %{"network_calls" => 1}} =
               Provider.generate_fr(input())
    end

    Req.Test.expect(Provider, fn conn -> Req.Test.json(conn, %{"choices" => []}) end)
    assert {:error, :incomplete_generation, _} = Provider.generate_fr(input())
  end

  test "unsafe provider labels are dropped while the requested model stays provenance" do
    Req.Test.expect(Provider, fn conn ->
      response =
        response(bundle())
        |> Map.put("id", "id with spaces <script>")
        |> Map.put("model", String.duplicate("m", 129))

      Req.Test.json(conn, response)
    end)

    assert {:ok, _, usage} = Provider.generate_fr(input())
    assert usage["model"] == @primary
    refute Map.has_key?(usage, "response_id")
    refute Map.has_key?(usage, "response_model")
  end

  test "rejects unknown, missing and duplicate refs, blank summaries and extra keys" do
    for output <- [
          put_in(bundle(), ["page", "claim_refs"], ["invented"]),
          put_in(bundle(), ["page", "claim_refs"], ["claim-1", "claim-1"]),
          put_in(bundle(), ["items", "1", "claim_refs"], []),
          put_in(bundle(), ["items", "1", "variant", "summary"], " "),
          Map.put(bundle(), "private", "secret"),
          put_in(bundle(), ["items", "1", "variant", "decision_summary"], "Adopted")
        ] do
      Req.Test.expect(Provider, fn conn -> Req.Test.json(conn, response(output)) end)

      # Invalid content is not retried on another model; its known cost is kept.
      assert {:error, :invalid_generation_output, %{"cost_cents" => 3, "network_calls" => 1}} =
               Provider.generate_fr(input())
    end
  end

  test "translation preserves exact references and variant keys" do
    for locale <- ["nl", "en"] do
      Req.Test.expect(Provider, fn conn -> Req.Test.json(conn, response(bundle())) end)
      assert {:ok, _, _} = Provider.translate(bundle(), locale)
    end

    for output <- [
          put_in(bundle(), ["items", "1", "claim_refs"], ["invented"]),
          put_in(bundle(), ["items", "1", "variant"], %{"title" => "x", "summary" => "y"})
        ] do
      Req.Test.expect(Provider, fn conn -> Req.Test.json(conn, response(output)) end)
      assert {:error, :invalid_generation_output, _} = Provider.translate(bundle(), "en")
    end

    assert {:error, :unsupported_locale, _} = Provider.translate(bundle(), "de")
  end

  test "truncated content, tool calls and refusal are never accepted" do
    for response <- [
          put_in(response(bundle()), ["choices", Access.at(0), "message", "refusal"], "refused"),
          put_in(response(bundle()), ["choices"], [
            %{"finish_reason" => "length", "message" => %{"content" => Jason.encode!(bundle())}}
          ]),
          put_in(response(bundle()), ["choices"], [
            %{
              "finish_reason" => "stop",
              "message" => %{
                "content" => Jason.encode!(bundle()),
                "tool_calls" => [%{"id" => "call"}]
              }
            }
          ])
        ] do
      Req.Test.expect(Provider, fn conn -> Req.Test.json(conn, response) end)
      assert {:error, _, %{"cost_cents" => 3}} = Provider.generate_fr(input())
    end
  end

  test "oversized response is bounded without leaking body" do
    Req.Test.expect(Provider, fn conn ->
      Plug.Conn.send_resp(conn, 200, String.duplicate("x", 262_145))
    end)

    assert {:error, :provider_response_too_large, %{"network_calls" => 1}} =
             Provider.generate_fr(input())
  end

  defp response(
         output,
         model_label \\ "qwen3.8-max-2026",
         {input, output_tokens} \\ {5_000, 2_000}
       ) do
    %{
      "id" => "chatcmpl-example",
      "model" => model_label,
      "choices" => [
        %{"finish_reason" => "stop", "message" => %{"content" => Jason.encode!(output)}}
      ],
      "usage" => %{"prompt_tokens" => input, "completion_tokens" => output_tokens}
    }
  end

  defp bundle do
    %{
      "meeting_identifier" => "meeting",
      "page" => %{
        "title" => "Proposal",
        "summary" => "Unknown outcome",
        "claim_refs" => ["claim-1"]
      },
      "items" => %{
        "1" => %{
          "claim_refs" => ["claim-1"],
          "variant" => %{
            "title" => "Proposal",
            "summary" => "Proposal",
            "proposal_summary" => "Unknown outcome"
          }
        }
      }
    }
  end

  defp input do
    %{
      "commune_slug" => "ixelles",
      "meeting_identifier" => "meeting",
      "scheduled_on" => "2026-09-01",
      "items" => [
        %{
          "key" => "1",
          "item_number" => "1",
          "procedural_state" => "proposal",
          "outcome" => "unknown",
          "source_wording" => "Proposal",
          "claims" => [
            %{
              "key" => "claim-1",
              "kind" => "proposal",
              "text" => "Proposal",
              "evidence" => [
                %{
                  "citation_url" => "https://www.ixelles.be/official.pdf",
                  "source_origin_url" => "https://www.ixelles.be/official.pdf",
                  "excerpt" => "Proposal",
                  "location" => "page 1",
                  "retrieved_at" => "2026-09-01T00:00:00Z",
                  "source_sha256" => String.duplicate("a", 64),
                  "synthetic" => false
                }
              ]
            }
          ]
        }
      ]
    }
  end
end
