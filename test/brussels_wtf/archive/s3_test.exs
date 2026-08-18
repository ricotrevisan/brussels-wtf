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
