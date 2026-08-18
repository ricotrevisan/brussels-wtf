defmodule BrusselsWtf.Contracts.RustfsTest do
  use ExUnit.Case, async: false

  @moduletag :external

  alias BrusselsWtf.Archive
  alias BrusselsWtf.Archive.S3

  @small_bytes "brussels.wtf ReqS3 rustFS contract v1\n"
  @small_sha256 "7a0d8c989837d2f205acf40c182c569bb9600285d7b5f23239514b2d72cb8026"
  @large_sha256 "281e519df3077b557c6b03f5da83c4e8d397219259615dd7c3308f89cae8f2a6"

  setup_all do
    names = %{
      endpoint: "RUSTFS_CONTRACT_ENDPOINT",
      bucket: "RUSTFS_CONTRACT_BUCKET",
      denied_bucket: "RUSTFS_CONTRACT_DENIED_BUCKET",
      region: "RUSTFS_CONTRACT_REGION",
      access_key_id: "RUSTFS_CONTRACT_ACCESS_KEY_ID",
      secret_access_key: "RUSTFS_CONTRACT_SECRET_ACCESS_KEY"
    }

    values = Map.new(names, fn {key, name} -> {key, System.fetch_env!(name)} end)
    previous_archive = Application.fetch_env!(:brussels_wtf, :archive)
    previous_s3 = Application.get_env(:brussels_wtf, S3)

    Application.put_env(:brussels_wtf, :archive, S3)

    Application.put_env(:brussels_wtf, S3,
      bucket: values.bucket,
      validation_prefix: "_validation/brussels-wtf-contract",
      req_options: [
        aws_endpoint_url_s3: values.endpoint,
        aws_sigv4: [
          access_key_id: values.access_key_id,
          secret_access_key: values.secret_access_key,
          region: values.region
        ]
      ]
    )

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :archive, previous_archive)

      if previous_s3 do
        Application.put_env(:brussels_wtf, S3, previous_s3)
      else
        Application.delete_env(:brussels_wtf, S3)
      end
    end)

    {:ok, values: values}
  end

  test "ReqS3 satisfies the real rustFS content-addressed archive contract" do
    assert {:ok, %{sha256: @small_sha256, object_key: object_key}} = Archive.store(@small_bytes)
    assert object_key == "raw/sha256/7a/#{@small_sha256}"
    assert {:ok, @small_bytes} = Archive.get(object_key)

    assert {:ok, %{sha256: @small_sha256, content_length: content_length}} =
             S3.metadata(object_key)

    assert content_length == byte_size(@small_bytes)

    assert {:ok, %{object_key: ^object_key}} = Archive.store(@small_bytes)
  end

  @tag timeout: :timer.minutes(5)
  test "ReqS3 stores and verifies a representative 64 MiB object" do
    bytes = :binary.copy(:binary.list_to_bin(Enum.to_list(0..255)), 262_144)
    assert byte_size(bytes) == 64 * 1_024 * 1_024

    assert {:ok, %{sha256: @large_sha256, object_key: object_key}} = Archive.store(bytes)
    assert {:ok, ^bytes} = Archive.get(object_key)

    assert {:ok, %{sha256: @large_sha256, content_length: content_length}} =
             S3.metadata(object_key)

    assert content_length == 64 * 1_024 * 1_024
  end

  test "validation prefix supports write, metadata, read, and delete" do
    assert :ok = S3.validate()
  end

  test "credentials cannot list buckets or access an operator-provisioned canary bucket", %{
    values: values
  } do
    request = Req.new() |> ReqS3.attach(request_options(values))
    denied_key = "_validation/brussels-wtf-contract/scope-canary"

    assert request_status(fn -> Req.get(request, url: "s3://") end) in 400..599

    assert request_status(fn ->
             Req.get(request, url: "s3://#{values.denied_bucket}/#{denied_key}")
           end) == 403

    assert request_status(fn ->
             Req.put(request,
               url: "s3://#{values.denied_bucket}/#{denied_key}",
               body: "scope probe"
             )
           end) == 403
  end

  test "the private object is not anonymously readable", %{values: values} do
    object_key = "raw/sha256/7a/#{@small_sha256}"
    assert {:ok, %{object_key: ^object_key}} = Archive.store(@small_bytes)

    unsigned_url =
      values.endpoint
      |> String.trim_trailing("/")
      |> Kernel.<>("/#{values.bucket}/#{object_key}")

    assert request_status(fn -> Req.get(unsigned_url, retry: false) end) in [401, 403]
  end

  defp request_options(values) do
    [
      raw: true,
      retry: false,
      receive_timeout: :timer.minutes(3),
      aws_endpoint_url_s3: values.endpoint,
      aws_sigv4: [
        access_key_id: values.access_key_id,
        secret_access_key: values.secret_access_key,
        region: values.region
      ]
    ]
  end

  defp request_status(request) do
    case request.() do
      {:ok, %{status: status}} -> status
      {:error, _reason} -> :unavailable
    end
  rescue
    _exception -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end
end
