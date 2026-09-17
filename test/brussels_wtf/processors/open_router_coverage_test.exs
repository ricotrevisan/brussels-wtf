defmodule BrusselsWtf.Processors.OpenRouterCoverageTest do
  use ExUnit.Case, async: false
  alias BrusselsWtf.Processors.OpenRouterCoverage, as: Provider
  @models ["stealth/union-alpha", "google/gemma-4-31b-it:free", "deepseek/deepseek-v4-flash-0731"]

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

  test "metadata declares paid network use and the pinned ordered fallback chain" do
    metadata = Provider.metadata()
    assert metadata.billing_mode == :paid
    assert metadata.network_access == :network
    assert metadata.model == Enum.join(@models, " -> ")
    assert metadata.allowed_models == @models
    assert {:ok, 3} = Provider.maximum_cost(:canonical_generation, %{})
    hash = metadata.config_hash
    Application.put_env(:brussels_wtf, Provider, api_key: "different-secret")
    assert Provider.metadata().config_hash == hash
    refute inspect(metadata) =~ "secret"
  end

  test "primary request carries fixed caps without disabling reasoning" do
    parent = self()

    Req.Test.expect(Provider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      data = Jason.decode!(body)
      send(parent, {:request, data})
      assert conn.request_path == "/api/v1/chat/completions"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret-test-key"]
      Req.Test.json(conn, response(bundle()))
    end)

    assert {:ok, output, usage} = Provider.generate_fr(input())
    assert output == bundle()

    assert Map.drop(usage, ["stages"]) == %{
             "network_calls" => 1,
             "model" => hd(@models),
             "input_tokens" => 100,
             "output_tokens" => 200,
             "cost_cents" => 1,
             "response_id" => "gen-example"
           }

    assert_received {:request, body}
    assert body["models"] == Enum.take(@models, 2)
    refute Map.has_key?(body, "reasoning")
    assert hd(body["messages"])["content"] =~ "does NOT establish adoption"
    assert hd(body["messages"])["content"] =~ "not yet adopted"
    assert body["max_tokens"] == 8_192
    assert body["stream"] == false

    assert body["provider"] == %{
             "max_price" => %{"prompt" => 0.06, "completion" => 0.18, "request" => 0},
             "require_parameters" => true,
             "data_collection" => "deny"
           }

    refute Map.has_key?(body, "tools")
    assert Jason.decode!(List.last(body["messages"])["content"]) == input()
  end

  test "retryable provider failure advances once to the paid singleton with reasoning disabled" do
    parent = self()

    Req.Test.expect(Provider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:primary, Jason.decode!(body)})
      conn |> Plug.Conn.put_status(429) |> Req.Test.json(response(bundle()))
    end)

    Req.Test.expect(Provider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:paid, Jason.decode!(body)})
      Req.Test.json(conn, response(bundle(), List.last(@models)))
    end)

    assert {:ok, _, usage} = Provider.generate_fr(input())
    assert_received {:primary, primary}
    assert_received {:paid, paid}
    assert primary["models"] == Enum.take(@models, 2)
    refute Map.has_key?(primary, "reasoning")
    assert paid["models"] == [List.last(@models)]
    assert paid["reasoning"] == %{"enabled" => false}
    assert Map.drop(paid, ["models", "reasoning"]) == Map.delete(primary, "models")
    assert usage["model"] == List.last(@models)
    assert usage["network_calls"] == 2
    assert usage["cost_cents"] == 2
    assert usage["input_tokens"] == 200
    assert usage["output_tokens"] == 400
    assert [first, second] = usage["stages"]
    assert first["status"] == "provider_http_error"
    assert first["http_status"] == 429
    assert first["response_id"] == "gen-example"
    assert second["status"] == "ok"
    assert second["model"] == List.last(@models)
  end

  test "all allowed models are accepted and missing cost remains unknown" do
    for model <- @models do
      if model == List.last(@models) do
        Req.Test.expect(Provider, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
      end

      Req.Test.expect(Provider, fn conn ->
        Req.Test.json(conn, Map.delete(response(bundle(), model), "usage"))
      end)

      assert {:ok, _, usage} = Provider.generate_fr(input())
      assert usage["model"] == model
      refute Map.has_key?(usage, "cost_cents")
    end
  end

  test "unknown cost from either stage remains unknown after a paid response" do
    for {first_cost, final_cost} <- [{nil, "0"}, {"0.001", nil}, {nil, nil}] do
      Req.Test.expect(Provider, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(put_in(response(bundle()), ["usage", "cost"], first_cost))
      end)

      Req.Test.expect(Provider, fn conn ->
        Req.Test.json(
          conn,
          put_in(response(bundle(), List.last(@models)), ["usage", "cost"], final_cost)
        )
      end)

      assert {:ok, _, usage} = Provider.translate(bundle(), "en")
      assert usage["network_calls"] == 2
      refute Map.has_key?(usage, "cost_cents")
    end
  end

  test "retryable failures stop after two requests and retain safe stage receipts" do
    for status <- [408, 429, 500, 503] do
      Req.Test.expect(Provider, 2, fn conn ->
        Plug.Conn.send_resp(conn, status, "secret-test-key private prompt")
      end)

      assert {:error, {:provider_http_error, %{http_status: ^status}}, usage} =
               result = Provider.generate_fr(input())

      assert usage["network_calls"] == 2
      assert length(usage["stages"]) == 2
      refute Map.has_key?(usage, "cost_cents")
      refute inspect(result) =~ "secret-test-key"
      refute inspect(result) =~ "private prompt"
    end
  end

  test "transport timeout advances to paid once and keeps the cancelled cost unknown" do
    parent = self()

    Req.Test.expect(Provider, fn conn ->
      send(parent, {:waiting_primary, self()})

      receive do
        :never -> conn
      end
    end)

    Req.Test.expect(Provider, fn conn ->
      Req.Test.json(conn, response(bundle(), List.last(@models)))
    end)

    started = System.monotonic_time(:millisecond)
    assert {:ok, _, usage} = Provider.generate_fr(input())
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 20_000 and elapsed < 25_000
    assert_received {:waiting_primary, pid}
    refute Process.alive?(pid)
    assert usage["network_calls"] == 2
    assert hd(usage["stages"])["status"] == "provider_wall_timeout"
    refute Map.has_key?(usage, "cost_cents")
  end

  test "configuration cannot override request limits or the paid reasoning policy" do
    Application.put_env(:brussels_wtf, Provider,
      api_key: "secret-test-key",
      plug: {Req.Test, Provider},
      req_options: [
        receive_timeout: 999_999,
        retry: true,
        redirect: true,
        json: %{"max_tokens" => 99_999}
      ]
    )

    Req.Test.expect(Provider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      data = Jason.decode!(body)
      assert data["max_tokens"] == 8_192
      assert data["provider"]["data_collection"] == "deny"
      assert data["models"] == Enum.take(@models, 2)
      refute Map.has_key?(data, "reasoning")
      Req.Test.json(conn, response(bundle()))
    end)

    assert {:ok, _, _} = Provider.generate_fr(input())
  end

  test "decimal-string costs round up without charging a free response" do
    for {cost, expected} <- [{"0", 0}, {"0.0000043", 1}, {"1.01", 101}] do
      Req.Test.expect(Provider, fn conn ->
        Req.Test.json(conn, put_in(response(bundle()), ["usage", "cost"], cost))
      end)

      assert {:ok, _, usage} = Provider.generate_fr(input())
      assert usage["cost_cents"] == expected
    end
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
  end

  test "nonretryable HTTP errors and redirects are sanitized and never retried" do
    for status <- [302, 400, 401, 402, 403, 404, 422] do
      Req.Test.expect(Provider, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://evil.example")
        |> Plug.Conn.send_resp(status, "secret-test-key private prompt")
      end)

      assert {:error, {:provider_http_error, %{http_status: ^status}}, usage} =
               result = Provider.generate_fr(input())

      assert usage["network_calls"] == 1
      refute Map.has_key?(usage, "cost_cents")
      refute inspect(result) =~ "secret-test-key"
      refute inspect(result) =~ "private prompt"
    end
  end

  test "unallowed model and malformed responses fail closed" do
    for body <- [
          "not json",
          Jason.encode!(response(bundle(), "unexpected/model")),
          Jason.encode!(response(bundle(), List.last(@models))),
          Jason.encode!(%{"choices" => []})
        ] do
      Req.Test.expect(Provider, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)

      assert {:error, :invalid_provider_response, %{"network_calls" => 1}} =
               Provider.generate_fr(input())
    end
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

      assert {:error, :invalid_generation_output, %{"cost_cents" => 1}} =
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
      assert {:error, _, %{"cost_cents" => 1}} = Provider.generate_fr(input())
    end
  end

  test "oversized response is bounded without leaking body" do
    Req.Test.expect(Provider, fn conn ->
      Plug.Conn.send_resp(conn, 200, String.duplicate("x", 262_145))
    end)

    assert {:error, :provider_response_too_large, %{"network_calls" => 1}} =
             Provider.generate_fr(input())
  end

  defp response(output, model \\ "stealth/union-alpha") do
    %{
      "id" => "gen-example",
      "model" => model,
      "choices" => [
        %{"finish_reason" => "stop", "message" => %{"content" => Jason.encode!(output)}}
      ],
      "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 200, "cost" => 0.001}
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
