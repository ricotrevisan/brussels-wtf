defmodule BrusselsWtf.Processors.OpenRouterCoverageTest do
  use ExUnit.Case, async: false
  alias BrusselsWtf.Processors.OpenRouterCoverage, as: Provider

  @models [
    "deepseek/deepseek-v4.1-flash",
    "deepseek/deepseek-v4-flash-0731",
    "google/gemini-2.5-flash-lite"
  ]
  @prices [
    %{"prompt" => 0.1, "completion" => 0.3, "request" => 0},
    %{"prompt" => 0.06, "completion" => 0.18, "request" => 0},
    %{"prompt" => 0.1, "completion" => 0.4, "request" => 0}
  ]

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

  test "metadata declares paid network use and the pinned ordered model stages" do
    metadata = Provider.metadata()
    assert metadata.billing_mode == :paid
    assert metadata.network_access == :network
    assert metadata.model == Enum.join(@models, " -> ")
    assert metadata.allowed_models == @models
    refute "stealth/union-alpha" in metadata.allowed_models
    refute Enum.any?(metadata.allowed_models, &String.ends_with?(&1, ":free"))
    assert {:ok, cents} = Provider.maximum_cost(:canonical_generation, input())
    assert cents in 1..3
    hash = metadata.config_hash
    Application.put_env(:brussels_wtf, Provider, api_key: "different-secret")
    assert Provider.metadata().config_hash == hash
    refute inspect(metadata) =~ "secret"
  end

  test "a single-batch request carries fixed caps, the primary model and disabled reasoning" do
    parent = self()

    Req.Test.expect(Provider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, Jason.decode!(body)})
      assert conn.request_path == "/api/v1/chat/completions"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret-test-key"]
      Req.Test.json(conn, response(bundle()))
    end)

    assert {:ok, output, usage} = Provider.generate_fr(input())
    assert output == bundle()

    assert Map.drop(usage, ["calls"]) == %{
             "network_calls" => 1,
             "batches" => 1,
             "model" => hd(@models),
             "input_tokens" => 100,
             "output_tokens" => 200,
             "cost_microusd" => 1_000,
             "cost_cents" => 1,
             "uncertain_cost_stages" => 0
           }

    assert [%{"part" => 1, "stages" => [stage]}] = usage["calls"]
    assert stage["status"] == "ok"
    assert stage["cost_known"]
    assert stage["response_id"] == "gen-example"

    assert_received {:request, body}
    assert body["model"] == hd(@models)
    refute Map.has_key?(body, "models")
    assert body["reasoning"] == %{"enabled" => false}
    assert hd(body["messages"])["content"] =~ "does NOT establish adoption"
    assert hd(body["messages"])["content"] =~ "not yet adopted"
    refute hd(body["messages"])["content"] =~ "batch"
    assert body["max_tokens"] == 16_384
    assert body["stream"] == false

    assert body["provider"] == %{
             "max_price" => hd(@prices),
             "sort" => "throughput",
             "require_parameters" => true,
             "data_collection" => "deny"
           }

    refute Map.has_key?(body, "tools")
    assert Jason.decode!(List.last(body["messages"])["content"]) == input()

    assert %{"type" => "json_schema", "json_schema" => %{"strict" => true, "schema" => schema}} =
             body["response_format"]

    assert schema["additionalProperties"] == false
    assert schema["required"] == ~w(items meeting_identifier page)
    assert schema["properties"]["meeting_identifier"]["enum"] == ["meeting"]
    item = schema["properties"]["items"]["properties"]["1"]
    assert schema["properties"]["items"]["required"] == ["1"]
    assert item["properties"]["claim_refs"]["items"]["enum"] == ["claim-1"]
    assert item["properties"]["variant"]["required"] == ~w(proposal_summary summary title)
    assert item["properties"]["variant"]["additionalProperties"] == false
  end

  test "retryable provider failures advance through each stage with its own price cap" do
    parent = self()

    for status <- [429, 503] do
      Req.Test.expect(Provider, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:stage, Jason.decode!(body)})
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => %{"code" => status}})
      end)
    end

    Req.Test.expect(Provider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:stage, Jason.decode!(body)})
      Req.Test.json(conn, response(bundle(), List.last(@models)))
    end)

    assert {:ok, _, usage} = Provider.generate_fr(input())

    bodies =
      for _ <- 1..3 do
        assert_received {:stage, body}
        body
      end

    assert Enum.map(bodies, & &1["model"]) == @models
    assert Enum.map(bodies, & &1["provider"]["max_price"]) == @prices
    assert Enum.all?(bodies, &(&1["reasoning"] == %{"enabled" => false}))

    assert Enum.uniq(Enum.map(bodies, &Map.drop(&1, ["model", "provider"]))) |> length() == 1

    assert usage["model"] == List.last(@models)
    assert usage["network_calls"] == 3
    assert usage["uncertain_cost_stages"] == 2
    assert [%{"stages" => [first, second, third]}] = usage["calls"]
    assert {first["status"], first["http_status"]} == {"provider_http_error", 429}
    assert {second["status"], second["http_status"]} == {"provider_http_error", 503}
    assert third["status"] == "ok"
    refute first["cost_known"] or second["cost_known"]
    # Uncertain stages are charged at their own conservative bound.
    assert first["cost_microusd"] > 0 and second["cost_microusd"] > 0
    assert usage["cost_microusd"] == first["cost_microusd"] + second["cost_microusd"] + 1_000
    assert {:ok, reserved} = Provider.maximum_cost(:canonical_generation, input())
    assert usage["cost_cents"] <= reserved
  end

  test "transport errors and routing 404s advance without exposing the provider body" do
    for message <- [
          "No endpoints found that support the requested parameters. private prompt",
          "No endpoints found matching your data policy. secret-test-key",
          "No endpoints found that match your preferences. private prompt"
        ] do
      Req.Test.expect(Provider, &Req.Test.transport_error(&1, :econnrefused))

      Req.Test.expect(Provider, fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => %{"code" => 404, "message" => message}})
      end)

      Req.Test.expect(Provider, fn conn ->
        Req.Test.json(conn, response(bundle(), List.last(@models)))
      end)

      assert {:ok, _, usage} = result = Provider.generate_fr(input())
      assert usage["network_calls"] == 3
      refute inspect(result) =~ "private prompt"
      refute inspect(result) =~ "secret-test-key"
    end
  end

  test "unrecognized routing bodies and non-retryable errors never advance" do
    for {status, body} <- [
          {404, %{"error" => %{"code" => 404, "message" => "Model not found"}}},
          {404,
           %{
             "error" => %{
               "code" => 400,
               "message" => "No endpoints found that match your preferences"
             }
           }},
          {404, %{"error" => %{"message" => "No endpoints found that match your preferences"}}},
          {401,
           %{
             "error" => %{
               "code" => 404,
               "message" => "No endpoints found that match your preferences"
             }
           }},
          {402, %{"error" => %{"code" => 402}}}
        ] do
      Req.Test.expect(Provider, fn conn ->
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end)

      assert {:error, {:provider_http_error, %{retryable: false}}, usage} =
               Provider.generate_fr(input())

      assert usage["network_calls"] == 1
    end
  end

  test "retryable failures stop after the last stage and retain safe receipts" do
    for status <- [408, 429, 500, 503] do
      Req.Test.expect(Provider, 3, fn conn ->
        Plug.Conn.send_resp(conn, status, "secret-test-key private prompt")
      end)

      assert {:error, {:provider_http_error, %{http_status: ^status}}, usage} =
               result = Provider.generate_fr(input())

      assert usage["network_calls"] == 3
      assert [%{"stages" => stages}] = usage["calls"]
      assert length(stages) == 3
      assert usage["uncertain_cost_stages"] == 3
      assert {:ok, reserved} = Provider.maximum_cost(:canonical_generation, input())
      assert usage["cost_cents"] in 1..reserved
      refute inspect(result) =~ "secret-test-key"
      refute inspect(result) =~ "private prompt"
    end
  end

  test "a meeting larger than one batch is generated in bounded batches and assembled" do
    input = input(20)
    parent = self()

    Req.Test.stub(Provider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      data = Jason.decode!(List.last(request["messages"])["content"])
      send(parent, {:request, request, data})

      if Map.has_key?(data, "commune_slug") and
           Enum.all?(data["items"], &Map.has_key?(&1, "title")) do
        Req.Test.json(conn, response(%{"title" => "Séance", "summary" => "Vingt points."}))
      else
        Req.Test.json(conn, response(bundle_for(data)))
      end
    end)

    assert {:ok, [first | _]} = Provider.batch_keys(input)
    assert first == Enum.map(1..8, &"#{&1}")
    assert {:ok, output, usage} = Provider.generate_fr(input)

    requests = collect_requests()
    assert length(requests) == 4

    {page_requests, batch_requests} =
      Enum.split_with(requests, fn {_, data} -> Map.has_key?(hd(data["items"]), "title") end)

    assert length(batch_requests) == 3

    assert Enum.map(batch_requests, fn {_, data} -> length(data["items"]) end) |> Enum.sort() == [
             4,
             8,
             8
           ]

    for {request, data} <- batch_requests do
      assert byte_size(Jason.encode!(data)) <= 65_536
      assert hd(request["messages"])["content"] =~ ~r/batch \d of 3/

      assert Map.keys(data) |> Enum.sort() ==
               ~w(commune_slug items meeting_identifier scheduled_on)
    end

    assert [{page_request, page_data}] = page_requests
    assert page_request["max_tokens"] == 2_048
    assert hd(page_request["messages"])["content"] =~ "exactly two keys, title and summary"
    assert length(page_data["items"]) == 20

    assert Map.keys(output["items"]) |> length() == 20
    assert output["page"]["title"] == "Séance"
    assert output["page"]["claim_refs"] == Enum.map(1..20, &"claim-#{&1}")
    assert :ok = BrusselsWtf.Council.GenerationContract.validate_bundle(input, output, "fr")

    assert usage["batches"] == 3
    assert usage["network_calls"] == 4
    assert usage["cost_microusd"] == 4_000
    assert usage["cost_cents"] == 1
    assert Enum.map(usage["calls"], & &1["part"]) == [1, 2, 3, "page"]
    assert {:ok, reserved} = Provider.maximum_cost(:canonical_generation, input)
    assert reserved >= usage["cost_cents"]
  end

  test "multi-batch translation keeps every reference and variant key" do
    canonical = bundle(20)
    parent = self()

    Req.Test.stub(Provider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      data = Jason.decode!(List.last(Jason.decode!(body)["messages"])["content"])
      send(parent, {:part, data})

      translated =
        data
        |> put_in(["page", "title"], "Vergadering")
        |> Map.update!("items", fn items ->
          Map.new(items, fn {key, item} ->
            {key, put_in(item, ["variant", "title"], "NL #{key}")}
          end)
        end)

      Req.Test.json(conn, response(translated))
    end)

    assert {:ok, output, usage} = Provider.translate(canonical, "nl")
    assert usage["batches"] == 3
    assert output["page"]["claim_refs"] == canonical["page"]["claim_refs"]
    assert output["page"]["title"] == "Vergadering"
    assert output["items"]["17"]["variant"]["title"] == "NL 17"
    assert Map.keys(output["items"]) == Map.keys(canonical["items"])

    parts =
      for _ <- 1..3 do
        assert_received {:part, data}
        data
      end

    for part <- parts do
      own = Enum.flat_map(part["items"], fn {_, item} -> item["claim_refs"] end)
      assert MapSet.new(part["page"]["claim_refs"]) == MapSet.new(own)
    end

    assert {:ok, reserved} =
             Provider.maximum_cost(:translation, %{"canonical" => canonical, "locale" => "nl"})

    assert reserved >= usage["cost_cents"]
  end

  test "a failed batch fails the whole operation and starts no further batch" do
    input = input(48)
    parent = self()

    Req.Test.stub(Provider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      data = Jason.decode!(List.last(Jason.decode!(body)["messages"])["content"])
      send(parent, {:batch, hd(data["items"])["key"]})

      if hd(data["items"])["key"] == "1" do
        Req.Test.json(
          conn,
          response(put_in(bundle_for(data), ["page", "claim_refs"], ["invented"]))
        )
      else
        Process.sleep(200)
        Req.Test.json(conn, response(bundle_for(data)))
      end
    end)

    assert {:error, :invalid_generation_output, usage} = Provider.generate_fr(input)
    # Six batches are planned; the four in flight finish, none start after the failure.
    assert {:ok, keys} = Provider.batch_keys(input)
    assert length(keys) == 6
    assert usage["network_calls"] == 4
    assert usage["batches"] == 4
    refute Enum.any?(usage["calls"], &(&1["part"] == "page"))
    assert usage["cost_microusd"] == 4_000
  end

  test "maximum cost covers every planned batch, the page call and every stage" do
    input = input(48)
    Req.Test.stub(Provider, fn conn -> Plug.Conn.send_resp(conn, 503, "busy") end)

    assert {:ok, reserved} = Provider.maximum_cost(:canonical_generation, input)
    assert {:error, {:provider_http_error, _}, usage} = Provider.generate_fr(input)
    assert usage["uncertain_cost_stages"] == usage["network_calls"]
    assert usage["cost_cents"] <= reserved
    assert reserved > elem(Provider.maximum_cost(:canonical_generation, input(8)), 1)
  end

  test "an item above the request cap or too many batches fails closed with no call" do
    Req.Test.stub(Provider, fn _ -> flunk("unexpected provider request") end)

    huge =
      put_in(input(), ["items", Access.at(0), "source_wording"], String.duplicate("a", 66_000))

    assert {:error, :input_too_large, %{"network_calls" => 0, "cost_cents" => 0}} =
             Provider.generate_fr(huge)

    assert {:ok, 1} = Provider.maximum_cost(:canonical_generation, huge)

    assert {:error, :input_too_large, %{"network_calls" => 0}} = Provider.generate_fr(input(200))
    assert {:ok, 1} = Provider.maximum_cost(:translation, %{"canonical" => %{}, "locale" => "nl"})
  end

  test "costs are summed in micro-USD and rounded up once per operation" do
    for {cost, microusd, cents} <- [
          {"0", 0, 0},
          {"0.0000043", 5, 1},
          {8.5896e-6, 9, 1},
          {"1.01", 1_010_000, 101}
        ] do
      Req.Test.expect(Provider, fn conn ->
        Req.Test.json(conn, put_in(response(bundle()), ["usage", "cost"], cost))
      end)

      assert {:ok, _, usage} = Provider.generate_fr(input())
      assert {usage["cost_microusd"], usage["cost_cents"]} == {microusd, cents}
    end
  end

  test "missing key and private extra keys make no network call" do
    Req.Test.stub(Provider, fn _ -> flunk("unexpected provider request") end)

    assert {:error, :invalid_publication_input, _} =
             Provider.generate_fr(Map.put(input(), "private_object_key", "private"))

    Application.put_env(:brussels_wtf, Provider, api_key: nil)
    assert {:error, :missing_api_key, %{"network_calls" => 0}} = Provider.generate_fr(input())
  end

  test "configuration cannot override request limits or the reasoning policy" do
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
      assert data["max_tokens"] == 16_384
      assert data["provider"]["data_collection"] == "deny"
      assert data["model"] == hd(@models)
      assert data["reasoning"] == %{"enabled" => false}
      Req.Test.json(conn, response(bundle()))
    end)

    assert {:ok, _, _} = Provider.generate_fr(input())
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
      refute inspect(result) =~ "secret-test-key"
      refute inspect(result) =~ "private prompt"
    end
  end

  test "a model other than the requested stage and malformed responses fail closed" do
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

  test "an invalid multi-batch page is rejected" do
    Req.Test.stub(Provider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      data = Jason.decode!(List.last(Jason.decode!(body)["messages"])["content"])

      if Map.has_key?(hd(data["items"]), "title"),
        do: Req.Test.json(conn, response(%{"title" => "Séance", "summary" => " "})),
        else: Req.Test.json(conn, response(bundle_for(data)))
    end)

    assert {:error, :invalid_generation_output, usage} = Provider.generate_fr(input(12))
    assert usage["network_calls"] == 3
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

      assert {:error, _, %{"cost_cents" => 1, "network_calls" => 1}} =
               Provider.generate_fr(input())
    end
  end

  test "oversized response is bounded without leaking body" do
    Req.Test.expect(Provider, fn conn ->
      Plug.Conn.send_resp(conn, 200, String.duplicate("x", 262_145))
    end)

    assert {:error, :provider_response_too_large, %{"network_calls" => 1}} =
             Provider.generate_fr(input())
  end

  defp collect_requests(acc \\ []) do
    receive do
      {:request, request, data} -> collect_requests([{request, data} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp response(output, model \\ "deepseek/deepseek-v4.1-flash") do
    %{
      "id" => "gen-example",
      "model" => model,
      "choices" => [
        %{"finish_reason" => "stop", "message" => %{"content" => Jason.encode!(output)}}
      ],
      "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 200, "cost" => 0.001}
    }
  end

  # A valid canonical response for exactly the items of one request.
  defp bundle_for(data) do
    refs = Enum.flat_map(data["items"], fn item -> Enum.map(item["claims"], & &1["key"]) end)

    %{
      "meeting_identifier" => data["meeting_identifier"],
      "page" => %{"title" => "Proposal", "summary" => "Unknown outcome", "claim_refs" => refs},
      "items" =>
        Map.new(data["items"], fn item ->
          {item["key"],
           %{
             "claim_refs" => Enum.map(item["claims"], & &1["key"]),
             "variant" => %{
               "title" => "Point #{item["key"]}",
               "summary" => "Proposal",
               "proposal_summary" => "Unknown outcome"
             }
           }}
        end)
    }
  end

  defp bundle(count \\ 1), do: bundle_for(input(count))

  defp input(count \\ 1) do
    %{
      "commune_slug" => "ixelles",
      "meeting_identifier" => "meeting",
      "scheduled_on" => "2026-09-01",
      "items" => Enum.map(1..count, &item/1)
    }
  end

  defp item(n) do
    %{
      "key" => "#{n}",
      "item_number" => "#{n}",
      "procedural_state" => "proposal",
      "outcome" => "unknown",
      "source_wording" => "Proposal",
      "claims" => [
        %{
          "key" => "claim-#{n}",
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
  end
end
