defmodule BrusselsWtf.Archive.S3Test do
  use ExUnit.Case, async: false

  alias BrusselsWtf.Archive
  alias BrusselsWtf.Archive.S3

  setup do
    previous_archive = Application.fetch_env!(:brussels_wtf, :archive)
    previous_s3 = Application.get_env(:brussels_wtf, S3)
    {:ok, objects} = Agent.start_link(fn -> %{} end)

    Application.put_env(:brussels_wtf, :archive, S3)

    Application.put_env(:brussels_wtf, S3,
      bucket: "preview-bucket",
      validation_prefix: "_validation/brussels-wtf",
      req_options: [
        plug: {Req.Test, S3},
        aws_endpoint_url_s3: "http://rustfs.test",
        aws_sigv4: [
          access_key_id: "test-access-key",
          secret_access_key: "test-secret-key",
          region: "garage"
        ]
      ]
    )

    Req.Test.stub(S3, fn conn ->
      key = String.trim_leading(conn.request_path, "/preview-bucket/")

      case conn.method do
        "PUT" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          [sha256] = Plug.Conn.get_req_header(conn, "x-amz-meta-sha256")
          assert sha256 == BrusselsWtf.Digest.sha256(body)
          assert Plug.Conn.get_req_header(conn, "if-none-match") == ["*"]

          if String.starts_with?(key, "raw/") do
            assert key == Archive.object_key(sha256)
          else
            assert String.starts_with?(key, "_validation/brussels-wtf/")
          end

          Agent.get_and_update(objects, fn stored ->
            if Map.has_key?(stored, key) do
              {Plug.Conn.send_resp(conn, 412, ""), stored}
            else
              {Plug.Conn.send_resp(conn, 200, ""), Map.put(stored, key, body)}
            end
          end)

        "HEAD" ->
          case Agent.get(objects, &Map.fetch(&1, key)) do
            {:ok, body} ->
              conn
              |> Plug.Conn.put_resp_header("content-length", Integer.to_string(byte_size(body)))
              |> Plug.Conn.put_resp_header("x-amz-meta-sha256", BrusselsWtf.Digest.sha256(body))
              |> Plug.Conn.send_resp(200, "")

            :error ->
              Plug.Conn.send_resp(conn, 404, "")
          end

        "GET" ->
          case Agent.get(objects, &Map.fetch(&1, key)) do
            {:ok, body} -> Plug.Conn.send_resp(conn, 200, body)
            :error -> Plug.Conn.send_resp(conn, 404, "")
          end

        "DELETE" ->
          Agent.get_and_update(objects, fn stored ->
            {Plug.Conn.send_resp(conn, 204, ""), Map.delete(stored, key)}
          end)
      end
    end)

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :archive, previous_archive)

      if previous_s3 do
        Application.put_env(:brussels_wtf, S3, previous_s3)
      else
        Application.delete_env(:brussels_wtf, S3)
      end
    end)

    %{objects: objects}
  end

  test "stores immutable source bytes through the configured path-style S3 bucket" do
    bytes = "captured authoritative bytes"
    sha256 = "fb51305de88c7c4357f2f0320a14edd140ee4501adc9af234123dc5569c71c2a"

    assert {:ok, %{sha256: ^sha256, object_key: object_key}} = Archive.store(bytes)
    assert object_key == "raw/sha256/fb/#{sha256}"
    assert {:ok, ^bytes} = Archive.get(object_key)

    assert {:ok, %{sha256: ^sha256, content_length: content_length}} =
             S3.metadata(object_key)

    assert content_length == byte_size(bytes)
    assert {:ok, %{object_key: ^object_key}} = Archive.store(bytes)
  end

  test "file upload is reopenable, signed unsigned-payload, and verified by streamed GET", %{
    objects: objects
  } do
    bytes = :binary.copy("source bytes\n", 10_000)
    path = source_file(bytes)
    sha256 = BrusselsWtf.Digest.sha256(bytes)
    test_pid = self()

    config = Application.fetch_env!(:brussels_wtf, S3)
    options = Keyword.fetch!(config, :req_options)

    adapter = fn request ->
      send(test_pid, {:archive_request, request.method})

      if request.method == :put do
        assert %File.Stream{} = request.body

        assert Req.Request.get_header(request, "content-length") == [
                 Integer.to_string(byte_size(bytes))
               ]

        assert Req.Request.get_header(request, "x-amz-content-sha256") == ["UNSIGNED-PAYLOAD"]
        assert Req.Request.get_header(request, "x-amz-meta-sha256") == [sha256]
        assert Enum.to_list(request.body) |> IO.iodata_to_binary() == bytes
        assert Enum.to_list(request.body) |> IO.iodata_to_binary() == bytes
      end

      if request.method == :get, do: assert(is_function(request.into, 2))
      run_stub(request)
    end

    Application.put_env(
      :brussels_wtf,
      S3,
      Keyword.put(
        config,
        :req_options,
        options |> Keyword.delete(:plug) |> Keyword.put(:adapter, adapter)
      )
    )

    assert {:ok, %{sha256: ^sha256, byte_size: size, object_key: key}} = Archive.store_file(path)
    assert size == byte_size(bytes)
    assert Agent.get(objects, &Map.fetch!(&1, key)) == bytes
    assert_received {:archive_request, :put}
    assert_received {:archive_request, :head}
    assert_received {:archive_request, :get}
    assert {:ok, %{object_key: ^key}} = Archive.store_file(path)
  end

  test "file verification rejects a colliding object even when HEAD metadata lies" do
    path = source_file("source")
    sha256 = BrusselsWtf.Digest.sha256("source")
    stub_file_object(sha256, 6, ["oth", "ers"], 412)
    assert {:error, :content_address_collision} = Archive.store_file(path)
  end

  test "new file writes require actual bytes, not matching HEAD metadata" do
    path = source_file("source")
    sha256 = BrusselsWtf.Digest.sha256("source")
    stub_file_object(sha256, 6, ["oth", "ers"])
    assert {:error, {:hash_mismatch, ^sha256, _}} = Archive.store_file(path)
  end

  test "streamed verification caps actual bytes before hashing and rejects short bodies" do
    sha256 = BrusselsWtf.Digest.sha256("source")
    key = Archive.object_key(sha256)
    stub_file_object(sha256, 6, ["source", "extra"])
    assert {:error, {:size_mismatch, 6, 11}} = S3.verify_file(key, sha256, 6)

    stub_file_object(sha256, 6, ["sou"])
    assert {:error, {:size_mismatch, 6, 3}} = S3.verify_file(key, sha256, 6)
  end

  test "verification rejects an encoded representation instead of expanding it" do
    sha256 = BrusselsWtf.Digest.sha256("source")

    Req.Test.stub(S3, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "gzip")
      |> Plug.Conn.send_resp(200, :zlib.gzip("source"))
    end)

    assert {:error, :unexpected_content_encoding} =
             S3.verify_file(Archive.object_key(sha256), sha256, 6)
  end

  test "a partial upload retry reopens the file from its beginning" do
    bytes = :binary.copy("source bytes\n", 10_000)
    path = source_file(bytes)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    config = Application.fetch_env!(:brussels_wtf, S3)
    options = Keyword.fetch!(config, :req_options)

    adapter = fn request ->
      if request.method == :put and Agent.get_and_update(attempts, &{&1, &1 + 1}) == 0 do
        assert [_first_chunk] = Enum.take(request.body, 1)
        {request, %Req.TransportError{reason: :timeout}}
      else
        run_stub(request)
      end
    end

    options =
      options
      |> Keyword.delete(:plug)
      |> Keyword.put(:adapter, adapter)
      |> Keyword.put(:retry_delay, fn _ -> 0 end)

    Application.put_env(:brussels_wtf, S3, Keyword.put(config, :req_options, options))
    assert {:ok, %{byte_size: size}} = Archive.store_file(path)
    assert size == byte_size(bytes)
    assert Agent.get(attempts, & &1) == 2
  end

  test "verification retries reset the incremental hash after a partial response" do
    bytes = "source"
    sha256 = BrusselsWtf.Digest.sha256(bytes)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    config = Application.fetch_env!(:brussels_wtf, S3)
    options = Keyword.fetch!(config, :req_options)

    adapter = fn request ->
      if Agent.get_and_update(attempts, &{&1, &1 + 1}) == 0 do
        response = Req.Response.new(status: 200)
        {:cont, {request, _response}} = request.into.({:data, "sou"}, {request, response})
        {request, %Req.TransportError{reason: :timeout}}
      else
        run_stub(request)
      end
    end

    options =
      options
      |> Keyword.delete(:plug)
      |> Keyword.put(:adapter, adapter)
      |> Keyword.put(:retry_delay, fn _ -> 0 end)

    Application.put_env(:brussels_wtf, S3, Keyword.put(config, :req_options, options))
    stub_file_object(sha256, 6, ["sou", "rce"])

    assert :ok = S3.verify_file(Archive.object_key(sha256), sha256, 6)
    assert Agent.get(attempts, & &1) == 2
  end

  test "changing the file after hashing cannot be accepted as the original snapshot" do
    path = source_file("source")
    config = Application.fetch_env!(:brussels_wtf, S3)
    options = Keyword.fetch!(config, :req_options)

    adapter = fn request ->
      if request.method == :put, do: File.write!(path, "others")
      run_stub(request)
    end

    options = options |> Keyword.delete(:plug) |> Keyword.put(:adapter, adapter)
    Application.put_env(:brussels_wtf, S3, Keyword.put(config, :req_options, options))

    Req.Test.stub(S3, fn conn ->
      case conn.method do
        "PUT" ->
          Plug.Conn.send_resp(conn, 200, "")

        "HEAD" ->
          conn
          |> Plug.Conn.put_resp_header("content-length", "6")
          |> Plug.Conn.put_resp_header("x-amz-meta-sha256", BrusselsWtf.Digest.sha256("source"))
          |> Plug.Conn.send_resp(200, "")

        "GET" ->
          Plug.Conn.send_resp(conn, 200, File.read!(path))
      end
    end)

    assert {:error, {:hash_mismatch, _, _}} = Archive.store_file(path)
  end

  test "an early closed immutable PUT requires streamed bytes but not HEAD metadata" do
    path = source_file("source")
    sha256 = BrusselsWtf.Digest.sha256("source")
    config = Application.fetch_env!(:brussels_wtf, S3)
    options = Keyword.fetch!(config, :req_options)

    adapter = fn request ->
      if request.method == :put do
        {request, %Req.TransportError{reason: :closed}}
      else
        run_stub(request)
      end
    end

    options =
      options
      |> Keyword.delete(:plug)
      |> Keyword.put(:adapter, adapter)
      |> Keyword.put(:retry, false)

    Application.put_env(:brussels_wtf, S3, Keyword.put(config, :req_options, options))

    Req.Test.stub(S3, fn conn ->
      assert conn.method == "GET"
      Plug.Conn.send_resp(conn, 200, "source")
    end)

    assert {:ok, %{sha256: ^sha256, byte_size: 6}} = Archive.store_file(path)

    Req.Test.stub(S3, fn conn -> Plug.Conn.send_resp(conn, 200, "others") end)
    assert {:error, {:hash_mismatch, ^sha256, _}} = Archive.store_file(path)

    Req.Test.stub(S3, fn conn -> Plug.Conn.send_resp(conn, 200, "short") end)
    assert {:error, {:size_mismatch, 6, 5}} = Archive.store_file(path)

    Req.Test.stub(S3, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
    assert {:error, :archive_unavailable} = Archive.store_file(path)

    Req.Test.stub(S3, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, :archive_unavailable} = Archive.store_file(path)
  end

  test "file upload rejects incorrect size and malformed SHA before sending" do
    path = source_file("source")
    sha256 = BrusselsWtf.Digest.sha256("source")
    assert {:error, {:size_mismatch, 5, 6}} = S3.put_file(:raw, sha256, path, 5)
    assert {:error, :invalid_sha256} = S3.put_file(:raw, "not-a-sha", path, 6)
  end

  test "verification reports remote failures without accepting a file" do
    path = source_file("source")
    sha256 = BrusselsWtf.Digest.sha256("source")

    Req.Test.stub(S3, fn conn ->
      case conn.method do
        "PUT" ->
          Plug.Conn.send_resp(conn, 200, "")

        "HEAD" ->
          conn
          |> Plug.Conn.put_resp_header("content-length", "6")
          |> Plug.Conn.put_resp_header("x-amz-meta-sha256", sha256)
          |> Plug.Conn.send_resp(200, "")

        "GET" ->
          Plug.Conn.send_resp(conn, 403, "private error")
      end
    end)

    assert {:error, {:archive_http_error, 403}} = Archive.store_file(path)
  end

  test "fetch_file streams a signed single GET into a private file without HEAD or binary buffering" do
    bytes = :binary.copy("synthetic bytes\n", 10_000)
    sha256 = BrusselsWtf.Digest.sha256(bytes)
    key = Archive.object_key(sha256, :derived)
    path = fetch_destination()

    stub_file_object(sha256, byte_size(bytes), [
      binary_part(bytes, 0, 50_000),
      binary_part(bytes, 50_000, byte_size(bytes) - 50_000)
    ])

    install_fetch_adapter(fn request ->
      assert request.method == :get
      assert is_function(request.into, 2)
      assert request.options.retry == false
      assert request.options.redirect == false
      assert request.options.raw == true
      assert request.options.receive_timeout == 1234
      assert Req.Request.get_header(request, "accept-encoding") == ["identity"]
      assert request.url.path == "/preview-bucket/#{key}"
      assert [_] = Req.Request.get_header(request, "authorization")
      run_stub(request)
    end)

    size = byte_size(bytes)

    assert {:ok, %{object_key: ^key, sha256: ^sha256, byte_size: ^size}} =
             Archive.fetch_file(key, sha256, size, path,
               max_bytes: size,
               receive_timeout_ms: 1234
             )

    assert File.read!(path) == bytes
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
  end

  test "fetch_file halts before an oversized chunk is written and removes the partial destination" do
    hash = BrusselsWtf.Digest.sha256("source")
    path = fetch_destination()

    install_fetch_adapter(fn request ->
      response = Req.Response.new(status: 200)
      {:cont, pair} = request.into.({:data, "source"}, {request, response})
      assert File.read!(path) == "source"
      {:halt, {request, response}} = request.into.({:data, "extra"}, pair)
      assert File.read!(path) == "source"
      {request, response}
    end)

    assert {:error, {:size_mismatch, 6, 11}} =
             Archive.fetch_file(Archive.object_key(hash), hash, 6, path, max_bytes: 10)

    refute File.exists?(path)
  end

  test "fetch_file rejects lying or encoded response headers before writing any chunk" do
    hash = BrusselsWtf.Digest.sha256("source")

    for {headers, reason} <- [
          {[{"content-length", "5"}], :invalid_content_length},
          {[{"content-length", "bogus"}], :invalid_content_length},
          {[{"content-length", "6, 6"}], :invalid_content_length},
          {[{"content-encoding", "gzip"}], :unexpected_content_encoding}
        ] do
      path = fetch_destination()
      parent = self()

      install_fetch_adapter(fn request ->
        response = Req.Response.new(status: 200, headers: headers)
        {action, {request, response}} = request.into.({:data, "source"}, {request, response})
        send(parent, {:header_rejection, action, File.read!(path)})
        {request, response}
      end)

      assert {:error, ^reason} =
               S3.fetch_file(Archive.object_key(hash), hash, 6, path, max_bytes: 9)

      assert_received {:header_rejection, :halt, ""}
      refute File.exists?(path)
    end
  end

  test "fetch_file wall deadline stops a stalled partial stream and removes its destination" do
    hash = BrusselsWtf.Digest.sha256("source")
    path = fetch_destination()
    parent = self()

    install_fetch_adapter(fn request ->
      response = Req.Response.new(status: 200)
      {:cont, _pair} = request.into.({:data, "sou"}, {request, response})
      send(parent, {:stream_worker, self()})
      Process.sleep(300)
      {request, response}
    end)

    assert {:error, :archive_timeout} =
             S3.fetch_file(Archive.object_key(hash), hash, 6, path, max_bytes: 9, timeout_ms: 50)

    assert_received {:stream_worker, worker}
    refute Process.alive?(worker)
    refute File.exists?(path)
  end

  test "fetch_file rejects corrupt and truncated streams even when hash metadata lies" do
    hash = BrusselsWtf.Digest.sha256("source")

    for {chunks, error} <- [
          {["oth", "ers"], {:hash_mismatch, hash, BrusselsWtf.Digest.sha256("others")}},
          {["sou"], {:size_mismatch, 6, 3}}
        ] do
      path = fetch_destination()

      Req.Test.stub(S3, fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_header("x-amz-meta-sha256", hash)
          |> Plug.Conn.send_chunked(200)

        Enum.reduce(chunks, conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)

      assert {:error, ^error} =
               Archive.fetch_file(Archive.object_key(hash), hash, 6, path, max_bytes: 9)

      refute File.exists?(path)
    end
  end

  test "fetch_file does not write or follow remote error and redirect bodies" do
    hash = BrusselsWtf.Digest.sha256("source")

    for status <- [301, 302, 307, 308, 404, 403, 500] do
      path = fetch_destination()
      parent = self()

      install_fetch_adapter(fn request ->
        response =
          Req.Response.new(
            status: status,
            headers: [{"location", "https://private.invalid/secret"}]
          )

        {action, {request, response}} =
          request.into.({:data, "private error"}, {request, response})

        send(parent, {:remote_rejection, action, File.read!(path)})
        {request, response}
      end)

      error = if status == 404, do: :not_found, else: {:archive_http_error, status}

      assert {:error, ^error} =
               Archive.fetch_file(Archive.object_key(hash), hash, 6, path, max_bytes: 9)

      assert_received {:remote_rejection, :halt, ""}
      refute File.exists?(path)
    end
  end

  test "fetch_file redacts partial transport failures and does not retry" do
    hash = BrusselsWtf.Digest.sha256("source")

    for kind <- [:transport, :exception, :throw] do
      path = fetch_destination()
      parent = self()

      install_fetch_adapter(fn request ->
        send(parent, :single_read)
        response = Req.Response.new(status: 200)
        {:cont, _pair} = request.into.({:data, "sou"}, {request, response})

        case kind do
          :transport -> {request, %Req.TransportError{reason: :timeout}}
          :exception -> raise "test-secret-key http://rustfs.test/private-object"
          :throw -> throw("test-secret-key http://rustfs.test/private-object")
        end
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :archive_unavailable} =
                   Archive.fetch_file(Archive.object_key(hash), hash, 6, path, max_bytes: 9)
        end)

      assert_received :single_read
      refute_received :single_read
      refute log =~ "test-secret-key"
      refute log =~ "rustfs.test"
      refute File.exists?(path)
    end
  end

  test "S3 fetch validates cap and identity before network access" do
    hash = BrusselsWtf.Digest.sha256("source")
    path = fetch_destination()
    parent = self()
    install_fetch_adapter(fn _ -> send(parent, :unexpected_fetch) end)

    for {key, hash, size, opts} <- [
          {Archive.object_key(hash), hash, 6, []},
          {Archive.object_key(hash), hash, 6, [max_bytes: 5]},
          {Archive.object_key(hash), "bad", 6, [max_bytes: 9]},
          {"private/path", hash, 6, [max_bytes: 9]},
          {Archive.object_key(hash), hash, -1, [max_bytes: 9]}
        ] do
      assert {:error, _} = S3.fetch_file(key, hash, size, path, opts)
    end

    refute_received :unexpected_fetch
    refute File.exists?(path)
  end

  test "fetch_file streams an oversized synthetic snapshot through the real HTTP transport" do
    chunk = :binary.copy("x", 64 * 1024)
    chunks = List.duplicate(chunk, 416)
    bytes = IO.iodata_to_binary(chunks)
    hash = BrusselsWtf.Digest.sha256(bytes)
    size = byte_size(bytes)
    path = fetch_destination()

    serve_fetch(fn socket ->
      :ok =
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        )

      for part <- chunks do
        :ok =
          :gen_tcp.send(socket, [Integer.to_string(byte_size(part), 16), "\r\n", part, "\r\n"])
      end

      :ok = :gen_tcp.send(socket, "0\r\n\r\n")
    end)

    assert {:ok, %{byte_size: ^size, sha256: ^hash}} =
             Archive.fetch_file(Archive.object_key(hash), hash, size, path, max_bytes: size)

    assert {:ok, %{byte_size: ^size, sha256: ^hash}} = BrusselsWtf.Digest.sha256_file(path)
    assert_received {:real_fetch_request, request}
    assert request =~ "GET /preview-bucket/raw/sha256/"
    assert String.downcase(request) =~ "accept-encoding: identity"
    assert String.downcase(request) =~ "authorization: aws4-hmac-sha256"
  end

  test "fetch_file enforces receive timeout on a real stalled socket" do
    hash = BrusselsWtf.Digest.sha256("source")
    path = fetch_destination()

    serve_fetch(fn socket ->
      :ok =
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nsou"
        )

      Process.sleep(300)
    end)

    assert {:error, :archive_unavailable} =
             Archive.fetch_file(Archive.object_key(hash), hash, 6, path,
               max_bytes: 9,
               receive_timeout_ms: 30,
               timeout_ms: 1000
             )

    assert_received {:real_fetch_request, _}
    refute File.exists?(path)
  end

  defp serve_fetch(respond) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)

        try do
          {:ok, request} = :gen_tcp.recv(socket, 0, 1000)
          send(parent, {:real_fetch_request, request})
          respond.(socket)
        after
          :gen_tcp.close(socket)
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server.pid), do: Process.exit(server.pid, :kill)
    end)

    config = Application.fetch_env!(:brussels_wtf, S3)

    options =
      config
      |> Keyword.fetch!(:req_options)
      |> Keyword.delete(:plug)
      |> Keyword.put(:aws_endpoint_url_s3, "http://127.0.0.1:#{port}")

    Application.put_env(:brussels_wtf, S3, Keyword.put(config, :req_options, options))
  end

  defmodule FetchAdapter do
    def run(request),
      do: Application.fetch_env!(:brussels_wtf, :archive_fetch_test_adapter).(request)
  end

  defp install_fetch_adapter(fun) do
    Application.put_env(:brussels_wtf, :archive_fetch_test_adapter, fun)
    on_exit(fn -> Application.delete_env(:brussels_wtf, :archive_fetch_test_adapter) end)
    config = Application.fetch_env!(:brussels_wtf, S3)

    options =
      config
      |> Keyword.fetch!(:req_options)
      |> Keyword.delete(:plug)
      |> Keyword.put(:adapter, FetchAdapter)

    Application.put_env(:brussels_wtf, S3, Keyword.put(config, :req_options, options))
  end

  defp fetch_destination do
    dir = Path.join(System.tmp_dir!(), "archive-s3-fetch-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    Path.join(dir, "snapshot")
  end

  defp run_stub(request) do
    Req.Plug.run(%{request | options: Map.put(request.options, :plug, {Req.Test, S3})})
  end

  defp stub_file_object(sha256, size, chunks, put_status \\ 200) do
    Req.Test.stub(S3, fn conn ->
      case conn.method do
        "PUT" ->
          Plug.Conn.send_resp(conn, put_status, "")

        "HEAD" ->
          conn
          |> Plug.Conn.put_resp_header("content-length", Integer.to_string(size))
          |> Plug.Conn.put_resp_header("x-amz-meta-sha256", sha256)
          |> Plug.Conn.send_resp(200, "")

        "GET" ->
          conn = Plug.Conn.send_chunked(conn, 200)

          Enum.reduce(chunks, conn, fn chunk, conn ->
            {:ok, conn} = Plug.Conn.chunk(conn, chunk)
            conn
          end)
      end
    end)
  end

  defp source_file(bytes) do
    path = Path.join(System.tmp_dir!(), "archive-s3-file-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "returns not_found without exposing the endpoint or credentials" do
    missing_sha = String.duplicate("0", 64)
    assert {:error, :not_found} = S3.get("raw/sha256/00/#{missing_sha}")
    assert {:error, :invalid_object_key} = S3.get("raw/sha256/00/not-a-digest")
  end

  test "normalizes unexpected client failures without logging private configuration" do
    Req.Test.stub(S3, fn _conn ->
      raise "test-secret-key http://rustfs.test/preview-bucket/private-object"
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        missing_sha = String.duplicate("0", 64)
        assert {:error, :archive_unavailable} = S3.get("raw/sha256/00/#{missing_sha}")
      end)

    refute log =~ "test-secret-key"
    refute log =~ "rustfs.test"
    refute log =~ "preview-bucket"
    refute log =~ "private-object"
  end

  test "readiness validates disposable write, metadata, read, and delete access", %{
    objects: objects
  } do
    assert :ok = S3.ready?()
    assert Agent.get(objects, & &1) == %{}
  end

  test "validates write, metadata, read, and delete access without leaving an object", %{
    objects: objects
  } do
    assert :ok = S3.validate()
    assert Agent.get(objects, & &1) == %{}
  end

  test "a failed validation operation still attempts bounded cleanup" do
    parent = self()

    Req.Test.stub(S3, fn conn ->
      case conn.method do
        "PUT" ->
          Plug.Conn.send_resp(conn, 200, "")

        "HEAD" ->
          Plug.Conn.send_resp(conn, 500, "")

        "DELETE" ->
          send(parent, :cleanup_attempted)
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    assert {:error, {:archive_validation_failed, :head, 500}} = S3.validate()
    assert_received :cleanup_attempted
  end

  test "release validation checks archive access before the web server starts", %{
    objects: objects
  } do
    assert ExUnit.CaptureIO.capture_io(fn ->
             assert :ok = BrusselsWtf.Release.validate_archive()
           end) == "Source archive validation passed\n"

    assert Agent.get(objects, & &1) == %{}
  end
end
