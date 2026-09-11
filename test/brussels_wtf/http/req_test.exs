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

    get "/transport-redirect" do
      conn
      |> put_resp_header("location", "relative déjà%20vu?title=conseil é#page 2")
      |> send_resp(302, "relative redirect")
    end

    get "/relative déjà vu" do
      location =
        "http://#{conn.host}:#{conn.port}/transport/pièce %2f.pdf" <>
          "?title=conseil é&encoded=%C3%A9%2f%26&next=/item?num=109&plus=a+b&literal=%2520&empty=#page 3"

      conn
      |> put_resp_header("location", location)
      |> send_resp(307, "absolute redirect")
    end

    get "/transport/*path" do
      target =
        conn.request_path <> if(conn.query_string == "", do: "", else: "?" <> conn.query_string)

      send_resp(conn, 200, target)
    end

    get "/show_documents/:date/:listing" do
      send_resp(conn, 200, conn.request_path)
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

  test "fetches a City item listing with raw spaces without changing its source URL", %{
    base_url: base_url
  } do
    url = base_url <> "/show_documents/07-09-2026/07 09 2026 OJ point_punt (109)"

    assert {:ok, response} = BrusselsWtf.HTTP.Req.get(url, [])
    assert response.status == 200

    assert response.body ==
             "/show_documents/07-09-2026/07%2009%202026%20OJ%20point_punt%20(109)"

    assert response.final_url == url
    assert response.redirect_chain == []
  end

  test "encodes UTF-8 path bytes without re-encoding existing escapes", %{base_url: base_url} do
    url = base_url <> "/transport/déjà %C3%A9%2f%2F%20rapport%.pdf"

    assert {:ok, response} = BrusselsWtf.HTTP.Req.get(url, [])
    assert response.status == 200
    assert response.body == "/transport/d%C3%A9j%C3%A0%20%C3%A9%2f%2F%20rapport%25.pdf"
    assert response.final_url == url
  end

  test "encodes queries and relative or absolute redirects only on the wire", %{
    base_url: base_url
  } do
    url = base_url <> "/transport-redirect?start=réunion %20#note 1"
    relative_location = "relative déjà%20vu?title=conseil é#page 2"
    intermediate_url = base_url <> "/" <> relative_location

    final_url =
      base_url <>
        "/transport/pièce %2f.pdf" <>
        "?title=conseil é&encoded=%C3%A9%2f%26&next=/item?num=109&plus=a+b&literal=%2520&empty=#page 3"

    assert {:ok, response} = BrusselsWtf.HTTP.Req.get(url, [])
    assert response.status == 200

    assert response.body ==
             "/transport/pi%C3%A8ce%20%2f.pdf" <>
               "?title=conseil%20%C3%A9&encoded=%C3%A9%2f%26&next=/item?num=109&plus=a+b&literal=%2520&empty="

    assert response.final_url == final_url

    assert [
             %{
               "status" => 302,
               "url" => ^url,
               "location" => ^intermediate_url,
               "headers" => %{"location" => [^relative_location]}
             },
             %{
               "status" => 307,
               "url" => ^intermediate_url,
               "location" => ^final_url,
               "headers" => %{"location" => [^final_url]}
             }
           ] = response.redirect_chain
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
