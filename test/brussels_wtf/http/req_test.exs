defmodule BrusselsWtf.HTTP.ReqTest do
  use ExUnit.Case, async: false

  defmodule Server do
    use Plug.Router

    @retry_counter BrusselsWtf.HTTP.ReqTest.RetryCounter

    plug :match
    plug :dispatch

    get "/redirect" do
      conn
      |> put_resp_header("location", "/document")
      |> send_resp(302, "redirecting")
    end

    get "/document" do
      if get_req_header(conn, "if-none-match") == ["fixture-etag"] do
        conn
        |> put_resp_header("etag", "fixture-etag")
        |> send_resp(304, "")
      else
        conn
        |> put_resp_header("etag", "fixture-etag")
        |> send_resp(200, "first bytes")
      end
    end

    get "/retry" do
      Agent.update(@retry_counter, &(&1 + 1))

      conn
      |> put_resp_header("retry-after", "900")
      |> send_resp(429, "slow down")
    end

    get "/large" do
      send_resp(conn, 200, String.duplicate("x", 2_048))
    end

    get "/slow" do
      Process.sleep(100)
      send_resp(conn, 200, "late")
    end
  end

  setup_all do
    start_supervised!(%{
      id: BrusselsWtf.HTTP.ReqTest.RetryCounter,
      start: {Agent, :start_link, [fn -> 0 end, [name: BrusselsWtf.HTTP.ReqTest.RetryCounter]]}
    })

    server = start_supervised!({Bandit, plug: Server, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    {:ok, base_url: "http://127.0.0.1:#{port}"}
  end

  test "preserves redirects and conditional-response metadata", %{base_url: base_url} do
    assert {:ok, response} = BrusselsWtf.HTTP.Req.get(base_url <> "/redirect", [])
    assert response.status == 200
    assert response.body == "first bytes"
    assert response.final_url == base_url <> "/document"

    assert [%{"status" => 302, "url" => redirect_url, "location" => final_url}] =
             response.redirect_chain

    assert redirect_url == base_url <> "/redirect"
    assert final_url == base_url <> "/document"

    assert {:ok, unchanged} =
             BrusselsWtf.HTTP.Req.get(base_url <> "/document",
               headers: %{"if-none-match" => ["fixture-etag"]}
             )

    assert unchanged.status == 304
    assert unchanged.headers["etag"] == ["fixture-etag"]
  end

  test "exposes Retry-After without hidden Req retries", %{base_url: base_url} do
    Agent.update(BrusselsWtf.HTTP.ReqTest.RetryCounter, fn _ -> 0 end)
    assert {:ok, response} = BrusselsWtf.HTTP.Req.get(base_url <> "/retry", [])
    assert response.status == 429
    assert response.headers["retry-after"] == ["900"]
    assert Agent.get(BrusselsWtf.HTTP.ReqTest.RetryCounter, & &1) == 1
  end

  test "halts oversized bodies and classifies receive timeouts safely", %{base_url: base_url} do
    assert {:error, %{reason: {:body_too_large, 1_024}}} =
             BrusselsWtf.HTTP.Req.get(base_url <> "/large", max_body_bytes: 1_024)

    assert {:error, %{reason: reason}} =
             BrusselsWtf.HTTP.Req.get(base_url <> "/slow", receive_timeout: 10)

    assert inspect(reason) =~ "timeout"
  end
end
