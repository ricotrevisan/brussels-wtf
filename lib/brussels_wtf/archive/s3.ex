defmodule BrusselsWtf.Archive.S3 do
  @moduledoc """
  Private content-addressed source archive backed by an S3-compatible bucket.

  ReqS3 supplies AWS Signature V4 and path-style endpoint support for rustFS.
  Credentials and the endpoint stay in the standard AWS runtime environment.
  """
  @behaviour BrusselsWtf.Archive

  alias BrusselsWtf.Archive
  alias BrusselsWtf.Digest

  @sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @object_key_pattern ~r/\Araw\/sha256\/([0-9a-f]{2})\/([0-9a-f]{64})\z/

  @impl true
  def put(sha256, bytes) when is_binary(sha256) and is_binary(bytes) do
    with :ok <- validate_content(sha256, bytes) do
      put_once(Archive.object_key(sha256), sha256, bytes)
    end
  end

  @impl true
  def get(object_key) when is_binary(object_key) do
    with :ok <- validate_object_key(object_key) do
      case Req.get(request(), url: object_url(object_key)) do
        {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
          {:ok, body}

        {:ok, %{status: 404}} ->
          {:error, :not_found}

        {:ok, %{status: status}} ->
          {:error, {:archive_http_error, status}}

        {:error, _reason} ->
          {:error, :archive_unavailable}
      end
    end
  end

  @doc "Validates write, metadata, read, and delete access under a disposable prefix."
  @spec validate() :: :ok | {:error, term()}
  def validate do
    bytes = :crypto.strong_rand_bytes(32)
    sha256 = Digest.sha256(bytes)
    object_key = validation_object_key()

    try do
      with :ok <- validation_put(object_key, sha256, bytes),
           :ok <- validation_head(object_key, sha256, byte_size(bytes)),
           :ok <- validation_get(object_key, bytes),
           :ok <- validation_delete(object_key),
           :ok <- validation_absent(object_key) do
        :ok
      end
    after
      cleanup_validation_object(object_key)
    end
  end

  defp validation_put(object_key, sha256, bytes) do
    request()
    |> Req.put(
      url: object_url(object_key),
      body: bytes,
      headers: [
        {"content-type", "application/octet-stream"},
        {"if-none-match", "*"},
        {"x-amz-meta-sha256", sha256}
      ]
    )
    |> validation_response(:put, 200..299)
  end

  defp validation_head(object_key, sha256, size) do
    case Req.head(request(), url: object_url(object_key)) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        metadata_sha256 = Req.Response.get_header(response, "x-amz-meta-sha256")
        content_length = Req.Response.get_header(response, "content-length")

        if metadata_sha256 == [sha256] and content_length == [Integer.to_string(size)] do
          :ok
        else
          {:error, {:archive_validation_failed, :metadata_mismatch}}
        end

      response ->
        validation_response(response, :head, 200..299)
    end
  end

  defp validation_get(object_key, expected_bytes) do
    case Req.get(request(), url: object_url(object_key)) do
      {:ok, %{status: status, body: ^expected_bytes}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} when status in 200..299 ->
        {:error, {:archive_validation_failed, :content_mismatch}}

      response ->
        validation_response(response, :get, 200..299)
    end
  end

  defp validation_delete(object_key) do
    request()
    |> Req.delete(url: object_url(object_key))
    |> validation_response(:delete, 200..299)
  end

  defp validation_absent(object_key) do
    case Req.get(request(), url: object_url(object_key)) do
      {:ok, %{status: 404}} -> :ok
      {:ok, %{status: status}} -> {:error, {:archive_validation_failed, :delete, status}}
      {:error, _reason} -> {:error, {:archive_validation_failed, :delete, :unavailable}}
    end
  end

  defp validation_response({:ok, %{status: status}}, _operation, _accepted)
       when status >= 200 and status <= 299,
       do: :ok

  defp validation_response({:ok, %{status: status}}, operation, _accepted),
    do: {:error, {:archive_validation_failed, operation, status}}

  defp validation_response({:error, _reason}, operation, _accepted),
    do: {:error, {:archive_validation_failed, operation, :unavailable}}

  defp cleanup_validation_object(object_key) do
    Req.delete(request(), url: object_url(object_key))
    :ok
  end

  defp validation_object_key do
    config = Application.fetch_env!(:brussels_wtf, __MODULE__)
    prefix = config |> Keyword.fetch!(:validation_prefix) |> String.trim("/")
    suffix = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    "#{prefix}/#{suffix}"
  end

  defp put_once(object_key, sha256, bytes) do
    case Req.put(request(),
           url: object_url(object_key),
           body: bytes,
           headers: [
             {"content-type", "application/octet-stream"},
             {"if-none-match", "*"},
             {"x-amz-meta-sha256", sha256}
           ]
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        {:ok, object_key}

      {:ok, %{status: status}} when status in [409, 412] ->
        verify_existing(object_key, bytes)

      {:ok, %{status: status}} ->
        {:error, {:archive_http_error, status}}

      {:error, _reason} ->
        {:error, :archive_unavailable}
    end
  end

  defp verify_existing(object_key, expected_bytes) do
    case get(object_key) do
      {:ok, ^expected_bytes} -> {:ok, object_key}
      {:ok, _different_bytes} -> {:error, :content_address_collision}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_content(sha256, bytes) do
    cond do
      not Regex.match?(@sha256_pattern, sha256) -> {:error, :invalid_sha256}
      Digest.sha256(bytes) != sha256 -> {:error, :sha256_mismatch}
      true -> :ok
    end
  end

  defp validate_object_key(object_key) do
    case Regex.run(@object_key_pattern, object_key) do
      [_, prefix, <<prefix::binary-size(2), _::binary>>] -> :ok
      _ -> {:error, :invalid_object_key}
    end
  end

  defp request do
    config = Application.fetch_env!(:brussels_wtf, __MODULE__)

    req_options =
      [
        raw: true,
        retry: :transient,
        max_retries: 2,
        retry_log_level: false,
        receive_timeout: 60_000
      ]
      |> Keyword.merge(Keyword.get(config, :req_options, []))

    Req.new()
    |> ReqS3.attach(req_options)
  end

  defp object_url(object_key) do
    bucket =
      :brussels_wtf
      |> Application.fetch_env!(__MODULE__)
      |> Keyword.fetch!(:bucket)

    "s3://#{bucket}/#{object_key}"
  end
end
