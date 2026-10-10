defmodule BrusselsWtf.Archive.S3 do
  @moduledoc """
  Private content-addressed source archive backed by an S3-compatible bucket.

  ReqS3 supplies AWS Signature V4 and path-style endpoint support for rustFS.
  Credentials and the endpoint stay in redacted application runtime configuration.
  """
  @behaviour BrusselsWtf.Archive

  alias BrusselsWtf.Archive
  alias BrusselsWtf.Digest

  @sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @object_key_pattern ~r/\A(?:raw|derived)\/sha256\/([0-9a-f]{2})\/([0-9a-f]{64})\z/

  @impl true
  def put(namespace, sha256, bytes)
      when namespace in [:raw, :derived] and is_binary(sha256) and is_binary(bytes) do
    safely(fn ->
      with :ok <- validate_content(sha256, bytes) do
        put_once(Archive.object_key(sha256, namespace), sha256, bytes)
      end
    end)
  end

  @impl true
  def put_file(namespace, sha256, path, size)
      when namespace in [:raw, :derived] and is_binary(sha256) and is_integer(size) and size >= 0 do
    safely(fn ->
      with true <- Regex.match?(@sha256_pattern, sha256),
           {:ok, %{size: ^size}} <- File.stat(path) do
        put_file_once(Archive.object_key(sha256, namespace), sha256, path, size)
      else
        false -> {:error, :invalid_sha256}
        {:ok, %{size: actual}} -> {:error, {:size_mismatch, size, actual}}
        {:error, reason} -> {:error, {:file_read, reason}}
      end
    end)
  end

  @impl true
  def verify_file(object_key, sha256, size)
      when is_binary(object_key) and is_binary(sha256) and is_integer(size) and size >= 0 do
    safely(fn ->
      with :ok <- validate_object_key(object_key) do
        verify_file_object(object_key, sha256, size)
      end
    end)
  end

  @impl true
  def get(object_key) when is_binary(object_key) do
    safely(fn ->
      with :ok <- validate_object_key(object_key) do
        get_object(object_key)
      end
    end)
  end

  @doc "Returns the stored checksum and byte length for a content-addressed object."
  @spec metadata(String.t()) ::
          {:ok, %{sha256: String.t(), content_length: non_neg_integer()}} | {:error, term()}
  def metadata(object_key) when is_binary(object_key) do
    safely(fn ->
      with :ok <- validate_object_key(object_key) do
        object_metadata(object_key)
      end
    end)
  end

  @impl true
  def ready?, do: validate()

  @doc "Validates write, metadata, read, and delete access under a disposable prefix."
  @spec validate() :: :ok | {:error, term()}
  def validate do
    safely(fn ->
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
    end)
  end

  defp validation_put(object_key, sha256, bytes) do
    validation_request()
    |> Req.put(
      url: object_url(object_key),
      body: bytes,
      headers: [
        {"content-type", "application/octet-stream"},
        {"if-none-match", "*"},
        {"x-amz-meta-sha256", sha256}
      ]
    )
    |> case do
      {:ok, %{status: status}} when status in 200..299 or status in [409, 412] -> :ok
      response -> validation_response(response, :put)
    end
  end

  defp validation_head(object_key, sha256, size) do
    case Req.head(validation_request(), url: object_url(object_key)) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        metadata_sha256 = Req.Response.get_header(response, "x-amz-meta-sha256")
        content_length = Req.Response.get_header(response, "content-length")

        if metadata_sha256 == [sha256] and content_length == [Integer.to_string(size)] do
          :ok
        else
          {:error, {:archive_validation_failed, :metadata_mismatch}}
        end

      response ->
        validation_response(response, :head)
    end
  end

  defp validation_get(object_key, expected_bytes) do
    case Req.get(validation_request(), url: object_url(object_key)) do
      {:ok, %{status: status, body: ^expected_bytes}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} when status in 200..299 ->
        {:error, {:archive_validation_failed, :content_mismatch}}

      response ->
        validation_response(response, :get)
    end
  end

  defp validation_delete(object_key) do
    validation_request()
    |> Req.delete(url: object_url(object_key))
    |> validation_response(:delete)
  end

  defp validation_absent(object_key) do
    case Req.get(validation_request(), url: object_url(object_key)) do
      {:ok, %{status: 404}} -> :ok
      {:ok, %{status: status}} -> {:error, {:archive_validation_failed, :delete, status}}
      {:error, _reason} -> {:error, {:archive_validation_failed, :delete, :unavailable}}
    end
  end

  defp validation_response({:ok, %{status: status}}, _operation)
       when status >= 200 and status <= 299,
       do: :ok

  defp validation_response({:ok, %{status: status}}, operation),
    do: {:error, {:archive_validation_failed, operation, status}}

  defp validation_response({:error, _reason}, operation),
    do: {:error, {:archive_validation_failed, operation, :unavailable}}

  defp cleanup_validation_object(object_key) do
    try do
      Req.delete(validation_request(), url: object_url(object_key))
      :ok
    rescue
      _exception -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp validation_object_key do
    config = Application.fetch_env!(:brussels_wtf, __MODULE__)
    prefix = config |> Keyword.fetch!(:validation_prefix) |> String.trim("/")
    suffix = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    "#{prefix}/#{suffix}"
  end

  defp put_file_once(object_key, sha256, path, size) do
    # File.Stream reopens the file for every enumeration, including a transport retry.
    case Req.put(request(redirect: false),
           url: object_url(object_key),
           body: File.stream!(path, 64 * 1_024),
           headers: [
             {"content-type", "application/octet-stream"},
             {"content-length", Integer.to_string(size)},
             {"if-none-match", "*"},
             {"x-amz-meta-sha256", sha256}
           ]
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        verify_stored_metadata(object_key, sha256, size)

      {:ok, %{status: status}} when status in [409, 412] ->
        verify_existing_file(object_key, sha256, size)

      {:ok, %{status: status}} ->
        {:error, {:archive_http_error, status}}

      {:error, %Req.TransportError{reason: :closed}} ->
        # rustFS may close an immutable PUT before Finch receives its early 412.
        # Only an existing, byte-verified object can resolve that ambiguous write.
        case verify_file(object_key, sha256, size) do
          :ok -> {:ok, object_key}
          {:error, :not_found} -> {:error, :archive_unavailable}
          {:error, reason} -> {:error, reason}
        end

      {:error, _reason} ->
        {:error, :archive_unavailable}
    end
  end

  defp verify_existing_file(object_key, sha256, size) do
    case verify_file(object_key, sha256, size) do
      :ok ->
        verify_stored_metadata(object_key, sha256, size)

      {:error, {mismatch, _, _}} when mismatch in [:hash_mismatch, :size_mismatch] ->
        {:error, :content_address_collision}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_file_object(object_key, sha256, size) do
    into = fn {:data, chunk}, {req, response} ->
      cond do
        response.status not in 200..299 ->
          {:halt, {req, response}}

        Req.Response.get_header(response, "content-encoding") not in [[], ["identity"]] ->
          response =
            Req.Response.put_private(response, :brussels_file_error, :unexpected_content_encoding)

          {:halt, {req, response}}

        true ->
          {context, count} =
            Req.Response.get_private(
              response,
              :brussels_file_hash,
              {:crypto.hash_init(:sha256), 0}
            )

          actual = count + byte_size(chunk)

          if actual > size do
            response =
              Req.Response.put_private(
                response,
                :brussels_file_error,
                {:size_mismatch, size, actual}
              )

            {:halt, {req, response}}
          else
            response =
              Req.Response.put_private(
                response,
                :brussels_file_hash,
                {:crypto.hash_update(context, chunk), actual}
              )

            {:cont, {req, response}}
          end
      end
    end

    case Req.get(request(redirect: false),
           url: object_url(object_key),
           headers: [{"accept-encoding", "identity"}],
           into: into
         ) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        verify_file_response(response, sha256, size)

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:archive_http_error, status}}

      {:error, _reason} ->
        {:error, :archive_unavailable}
    end
  end

  defp verify_file_response(response, sha256, size) do
    {context, actual_size} =
      Req.Response.get_private(response, :brussels_file_hash, {:crypto.hash_init(:sha256), 0})

    cond do
      error = Req.Response.get_private(response, :brussels_file_error) ->
        {:error, error}

      Req.Response.get_header(response, "content-encoding") not in [[], ["identity"]] ->
        {:error, :unexpected_content_encoding}

      actual_size != size ->
        {:error, {:size_mismatch, size, actual_size}}

      true ->
        actual_sha256 = Base.encode16(:crypto.hash_final(context), case: :lower)

        if actual_sha256 == sha256,
          do: :ok,
          else: {:error, {:hash_mismatch, sha256, actual_sha256}}
    end
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
        verify_stored_metadata(object_key, sha256, byte_size(bytes))

      {:ok, %{status: status}} when status in [409, 412] ->
        with {:ok, ^object_key} <- verify_existing(object_key, bytes) do
          verify_stored_metadata(object_key, sha256, byte_size(bytes))
        end

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

  defp get_object(object_key) do
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

  defp object_metadata(object_key) do
    case head_metadata(object_key) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, 404} -> {:error, :not_found}
      {:error, status} when is_integer(status) -> {:error, {:archive_http_error, status}}
      {:error, :unavailable} -> {:error, :archive_unavailable}
      {:error, :invalid_metadata} -> {:error, :invalid_metadata}
    end
  end

  defp head_metadata(object_key) do
    case Req.head(request(), url: object_url(object_key)) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        with [sha256] <- Req.Response.get_header(response, "x-amz-meta-sha256"),
             true <- Regex.match?(@sha256_pattern, sha256),
             [length] <- Req.Response.get_header(response, "content-length"),
             {content_length, ""} <- Integer.parse(length) do
          {:ok, %{sha256: sha256, content_length: content_length}}
        else
          _other -> {:error, :invalid_metadata}
        end

      {:ok, %{status: status}} ->
        {:error, status}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp verify_stored_metadata(object_key, sha256, size) do
    case head_metadata(object_key) do
      {:ok, %{sha256: ^sha256, content_length: ^size}} -> {:ok, object_key}
      {:ok, _metadata} -> {:error, :metadata_mismatch}
      {:error, _reason} -> {:error, :archive_unavailable}
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    _exception -> {:error, :archive_unavailable}
  catch
    _kind, _reason -> {:error, :archive_unavailable}
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

  # Validation uses short, non-retrying requests so all five operations and
  # best-effort cleanup finish well inside the readiness monitor deadline.
  defp validation_request do
    request(retry: false, receive_timeout: 5_000)
  end

  defp request(overrides \\ []) do
    config = Application.fetch_env!(:brussels_wtf, __MODULE__)

    req_options =
      [
        raw: true,
        retry: :transient,
        max_retries: 2,
        retry_delay: fn retry_count -> 500 * (retry_count + 1) end,
        retry_log_level: false,
        receive_timeout: 60_000
      ]
      |> Keyword.merge(Keyword.get(config, :req_options, []))
      |> Keyword.merge(overrides)

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
