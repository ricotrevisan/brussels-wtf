defmodule BrusselsWtf.HTTP.Req do
  @moduledoc false
  @behaviour BrusselsWtf.HTTP

  @redirect_statuses [301, 302, 303, 307, 308]
  @max_redirects 10
  @default_max_body_bytes 25 * 1_024 * 1_024
  @default_receive_timeout 30_000

  @impl true
  def get(url, opts) do
    request = %{
      headers: request_headers(opts),
      max_body_bytes: Keyword.get(opts, :max_body_bytes, configured_max_body_bytes()),
      receive_timeout: Keyword.get(opts, :receive_timeout, configured_receive_timeout())
    }

    follow(url, [], @max_redirects, request)
  end

  defp follow(url, chain, 0, _request) do
    {:error,
     %{
       reason: :too_many_redirects,
       final_url: url,
       response_headers: %{},
       redirect_chain: chain
     }}
  end

  defp follow(url, chain, remaining, request) do
    case request(url, request) do
      {:ok, %Req.Response{status: status, headers: headers} = response}
      when status in @redirect_statuses ->
        case first_header(headers, "location") do
          nil ->
            response(response, url, chain, request.max_body_bytes)

          location ->
            next_url = url |> URI.merge(location) |> URI.to_string()

            redirect = %{
              "status" => status,
              "url" => url,
              "location" => next_url,
              "headers" => normalize_headers(headers)
            }

            follow(next_url, chain ++ [redirect], remaining - 1, request)
        end

      {:ok, %Req.Response{} = response} ->
        response(response, url, chain, request.max_body_bytes)

      {:error, reason} ->
        {:error,
         %{
           reason: reason,
           final_url: url,
           response_headers: %{},
           redirect_chain: chain
         }}
    end
  end

  defp request(url, request) do
    Req.get(transport_url(url),
      redirect: false,
      retry: false,
      decode_body: false,
      headers: request.headers,
      receive_timeout: request.receive_timeout,
      into: bounded_body(request.max_body_bytes)
    )
  end

  defp transport_url(url) do
    uri = URI.parse(url)
    # Keep source and redirect URLs unchanged; only the HTTP request target is encoded.
    %{uri | path: encode_target_component(uri.path), query: encode_target_component(uri.query)}
  end

  defp encode_target_component(nil), do: nil

  defp encode_target_component(value) do
    value
    |> String.replace(~r/%(?![0-9A-Fa-f]{2})/, "%25")
    |> URI.encode(&(URI.char_unescaped?(&1) or &1 == ?%))
  end

  defp bounded_body(max_body_bytes) do
    fn {:data, data}, {request, response} ->
      body = response.body || ""
      size = iodata_size(body) + byte_size(data)

      if size > max_body_bytes do
        {:halt, {request, %{response | body: {:body_too_large, max_body_bytes}}}}
      else
        {:cont, {request, %{response | body: [body, data]}}}
      end
    end
  end

  defp response(%Req.Response{body: {:body_too_large, limit}} = response, final_url, chain, _max) do
    {:error,
     %{
       reason: {:body_too_large, limit},
       final_url: final_url,
       response_headers: normalize_headers(response.headers),
       redirect_chain: chain
     }}
  end

  defp response(response, final_url, chain, max_body_bytes) do
    body = IO.iodata_to_binary(response.body || "")

    if byte_size(body) > max_body_bytes do
      {:error,
       %{
         reason: {:body_too_large, max_body_bytes},
         final_url: final_url,
         response_headers: normalize_headers(response.headers),
         redirect_chain: chain
       }}
    else
      {:ok,
       %{
         status: response.status,
         headers: normalize_headers(response.headers),
         body: body,
         final_url: final_url,
         redirect_chain: chain
       }}
    end
  end

  defp request_headers(opts) do
    opts
    |> Keyword.get(:headers, %{})
    |> Enum.flat_map(fn {key, values} -> Enum.map(List.wrap(values), &{to_string(key), &1}) end)
  end

  defp first_header(headers, name) do
    headers
    |> normalize_headers()
    |> Map.get(name, [])
    |> List.first()
  end

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {key, values} -> {String.downcase(to_string(key)), List.wrap(values)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.reduce(headers, %{}, fn {key, value}, result ->
      Map.update(result, String.downcase(to_string(key)), [value], &(&1 ++ [value]))
    end)
  end

  defp iodata_size(data) do
    IO.iodata_length(data)
  rescue
    _ -> 0
  end

  defp configured_max_body_bytes do
    Application.get_env(:brussels_wtf, :http_max_body_bytes, @default_max_body_bytes)
  end

  defp configured_receive_timeout do
    Application.get_env(:brussels_wtf, :http_receive_timeout, @default_receive_timeout)
  end
end
