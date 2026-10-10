defmodule BrusselsWtf.HTTP.DownloadTest do
  use ExUnit.Case, async: false

  alias BrusselsWtf.HTTP
  alias BrusselsWtf.Test.ControllableHTTPServer

  setup do
    original = Application.fetch_env!(:brussels_wtf, :http)
    Application.put_env(:brussels_wtf, :http, HTTP.Req)
    server = ControllableHTTPServer.start()

    directory =
      Path.join(System.tmp_dir!(), "brussels-http-download-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :http, original)
      ControllableHTTPServer.stop(server)
      File.rm_rf!(directory)
    end)

    {:ok, server: server, destination: Path.join(directory, "source")}
  end

  test "downloads source bytes to a caller-owned file without returning a body", %{
    server: server,
    destination: destination
  } do
    ControllableHTTPServer.put(server, "/document", %{
      body: "%PDF-fixture",
      headers: %{"etag" => "fixture-etag"}
    })

    url = server.base_url <> "/document"
    assert {:ok, response} = HTTP.download(url, destination, max_body_bytes: 12)
    assert response.status == 200
    assert response.byte_size == 12
    assert response.headers["etag"] == ["fixture-etag"]
    assert response.final_url == url
    assert response.redirect_chain == []
    refute Map.has_key?(response, :body)
    assert File.read!(destination) == "%PDF-fixture"

    assert [%{headers: %{"accept-encoding" => "identity"}}] =
             ControllableHTTPServer.requests(server, "/document")
  end

  test "caps actual chunked source bytes without accepting or extending a partial file", %{
    server: server,
    destination: destination
  } do
    ControllableHTTPServer.put(server, "/chunked", %{chunks: ["1234", "5678"]})

    assert {:ok, %{byte_size: 8, headers: headers}} =
             HTTP.download(server.base_url <> "/chunked", destination, max_body_bytes: 8)

    refute Map.has_key?(headers, "content-length")
    assert File.read!(destination) == "12345678"

    ControllableHTTPServer.put(server, "/chunked", %{chunks: ["1234", "5678", "9"]})

    assert {:error, %{reason: {:body_too_large, 8}}} =
             HTTP.download(server.base_url <> "/chunked", destination, max_body_bytes: 8)

    assert File.stat!(destination).size <= 8
  end

  test "discards redirect and error bodies while preserving status metadata", %{
    server: server,
    destination: destination
  } do
    ControllableHTTPServer.put(server, "/redirect", %{
      status: 302,
      body: "redirect body",
      headers: %{"location" => "/document"}
    })

    ControllableHTTPServer.put(server, "/document", %{body: "%PDF"})

    assert {:ok, %{byte_size: 4, redirect_chain: [%{"status" => 302}]}} =
             HTTP.download(server.base_url <> "/redirect", destination, max_body_bytes: 4)

    assert File.read!(destination) == "%PDF"

    ControllableHTTPServer.put(server, "/retry", %{
      status: 429,
      body: "untrusted error body",
      headers: %{"retry-after" => "900"}
    })

    assert {:ok, %{status: 429, byte_size: 0, headers: %{"retry-after" => ["900"]}}} =
             HTTP.download(server.base_url <> "/retry", destination, max_body_bytes: 4)

    assert File.read!(destination) == ""
    assert length(ControllableHTTPServer.requests(server, "/retry")) == 1
  end

  test "rejects encoded source bytes and oversized declarations before writing", %{
    server: server,
    destination: destination
  } do
    ControllableHTTPServer.put(server, "/encoded", %{
      body: "encoded",
      headers: %{"content-encoding" => "gzip"}
    })

    assert {:error, %{reason: {:unsupported_content_encoding, ["gzip"]}}} =
             HTTP.download(server.base_url <> "/encoded", destination)

    assert File.read!(destination) == ""

    ControllableHTTPServer.put(server, "/declared", %{body: "123456789"})

    assert {:error, %{reason: {:body_too_large, 8}, response_headers: headers}} =
             HTTP.download(server.base_url <> "/declared", destination, max_body_bytes: 8)

    assert headers["content-length"] == ["9"]
    assert File.read!(destination) == ""
  end

  test "reports file open and file write errors without source-byte success", %{
    server: server,
    destination: destination
  } do
    ControllableHTTPServer.put(server, "/document", %{body: "%PDF"})

    assert {:error, %{reason: {:file_write, :enoent}}} =
             HTTP.download(server.base_url <> "/document", Path.join(destination, "missing"))

    if File.exists?("/dev/full") do
      assert {:error, %{reason: {:file_write, :enospc}}} =
               HTTP.download(server.base_url <> "/document", "/dev/full")
    end
  end

  test "keeps exact source and redirect URLs while encoding only the transport target", %{
    server: server,
    destination: destination
  } do
    url = server.base_url <> "/start?meeting=réunion %20#note 1"
    relative = "pièce %2f.pdf?title=conseil é&encoded=%C3%A9%2f%26&plus=a+b&literal=%2520#page 3"
    final_url = server.base_url <> "/" <> relative
    encoded_path = "/pi%C3%A8ce%20%2f.pdf"

    ControllableHTTPServer.put(server, "/start", %{
      status: 307,
      body: "redirect",
      headers: %{"location" => relative}
    })

    ControllableHTTPServer.put(server, encoded_path, %{body: "%PDF"})

    assert {:ok, response} = HTTP.download(url, destination)
    assert response.final_url == final_url

    assert [%{"url" => ^url, "location" => ^final_url, "headers" => %{"location" => [^relative]}}] =
             response.redirect_chain

    assert [%{query_string: "meeting=r%C3%A9union%20%20"}] =
             ControllableHTTPServer.requests(server, "/start")

    assert [%{query_string: "title=conseil%20%C3%A9&encoded=%C3%A9%2f%26&plus=a+b&literal=%2520"}] =
             ControllableHTTPServer.requests(server, encoded_path)

    assert File.read!(destination) == "%PDF"
  end

  test "preserves conditional 304 metadata and stops redirect loops", %{
    server: server,
    destination: destination
  } do
    File.write!(destination, "stale bytes")

    ControllableHTTPServer.put(server, "/unchanged", %{
      status: 304,
      headers: %{"etag" => "fixture-etag", "last-modified" => "Mon, 07 Sep 2026 10:00:00 GMT"}
    })

    assert {:ok, %{status: 304, byte_size: 0, headers: headers}} =
             HTTP.download(server.base_url <> "/unchanged", destination,
               headers: %{
                 "if-none-match" => "fixture-etag",
                 "if-modified-since" => "Mon, 07 Sep 2026 10:00:00 GMT",
                 "Accept-Encoding" => "gzip"
               }
             )

    assert headers["etag"] == ["fixture-etag"]
    assert headers["last-modified"] == ["Mon, 07 Sep 2026 10:00:00 GMT"]

    assert [
             %{
               headers: %{
                 "if-none-match" => "fixture-etag",
                 "if-modified-since" => "Mon, 07 Sep 2026 10:00:00 GMT",
                 "accept-encoding" => "identity"
               }
             }
           ] = ControllableHTTPServer.requests(server, "/unchanged")

    assert File.read!(destination) == ""

    ControllableHTTPServer.put(server, "/loop", %{
      status: 302,
      body: "redirect",
      headers: %{"location" => "/loop"}
    })

    assert {:error, %{reason: :too_many_redirects, redirect_chain: chain}} =
             HTTP.download(server.base_url <> "/loop", destination)

    assert length(chain) == 10
    assert File.read!(destination) == ""
  end

  test "fails interrupted and stalled transfers instead of accepting partial bytes", %{
    server: server,
    destination: destination
  } do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n%PDF\r\n"
          )

        :gen_tcp.close(socket)
      end)

    assert {:error, %{reason: reason}} =
             HTTP.download("http://127.0.0.1:#{port}/interrupted", destination)

    assert inspect(reason) =~ "closed"
    assert File.stat!(destination).size <= 4
    Task.await(task)

    ControllableHTTPServer.put(server, "/slow", %{body: "late", delay_ms: 100})

    assert {:error, %{reason: reason}} =
             HTTP.download(server.base_url <> "/slow", destination, receive_timeout: 10)

    assert inspect(reason) =~ "timeout"
    assert File.read!(destination) == ""
  end

  test "rejects partial and empty successful HTTP statuses instead of archiving empty source bytes",
       %{
         server: server,
         destination: destination
       } do
    for status <- [201, 204, 206] do
      ControllableHTTPServer.put(server, "/partial", %{
        status: status,
        body: if(status == 204, do: "", else: "%PDF")
      })

      assert {:error, %{reason: {:invalid_content, {:unexpected_success_status, ^status}}}} =
               HTTP.download(server.base_url <> "/partial", destination)

      assert File.read!(destination) == ""
    end
  end

  test "rejects an interrupted declared-length response and ambiguous chunked length", %{
    destination: destination
  } do
    for response <- [
          "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\n%PDF",
          "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n%PDF\r\n0\r\n\r\n"
        ] do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

      {:ok, {_ip, port}} = :inet.sockname(listener)

      task =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)
          :ok = :gen_tcp.send(socket, response)
          :gen_tcp.close(socket)
        end)

      try do
        assert {:error, %{reason: _reason}} =
                 HTTP.download("http://127.0.0.1:#{port}/invalid-framing", destination,
                   max_body_bytes: 8
                 )

        assert File.stat!(destination).size <= 8
        Task.await(task)
      after
        :gen_tcp.close(listener)
      end
    end
  end
end
