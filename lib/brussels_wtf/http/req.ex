defmodule BrusselsWtf.HTTP.Req do
  @moduledoc false
  @behaviour BrusselsWtf.HTTP

  @redirect_statuses [301, 302, 303, 307, 308]
  @max_redirects 10

  @impl true
  def get(url, opts), do: follow(url, [], @max_redirects, request_headers(opts))

  defp follow(url, chain, 0, _headers) do
    {:error,
     %{
       reason: :too_many_redirects,
       final_url: url,
       response_headers: %{},
       redirect_chain: chain
     }}
  end

  defp follow(url, chain, remaining, request_headers) do
    case Req.get(url, redirect: false, decode_body: false, headers: request_headers) do
      {:ok, %Req.Response{status: status, headers: headers} = response}
      when status in @redirect_statuses ->
        case first_header(headers, "location") do
          nil ->
            response(response, url, chain)

          location ->
            next_url = url |> URI.merge(location) |> URI.to_string()

            redirect = %{
              "status" => status,
              "url" => url,
              "location" => next_url,
              "headers" => normalize_headers(headers)
            }

            follow(next_url, chain ++ [redirect], remaining - 1, request_headers)
        end

      {:ok, %Req.Response{} = response} ->
        response(response, url, chain)

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

  defp response(response, final_url, chain) do
    {:ok,
     %{
       status: response.status,
       headers: normalize_headers(response.headers),
       body: IO.iodata_to_binary(response.body || ""),
       final_url: final_url,
       redirect_chain: chain
     }}
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
end
