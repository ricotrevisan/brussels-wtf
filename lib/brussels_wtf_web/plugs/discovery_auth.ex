defmodule BrusselsWtfWeb.Plugs.DiscoveryAuth do
  @moduledoc false
  import Plug.Conn
  alias BrusselsWtf.Discovery

  def init(opts), do: opts

  # Before body parsing: unauthenticated requests never materialize source payloads.
  def call(%{path_info: ["internal", "discovery" | _]} = conn, _opts) do
    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] when byte_size(token) <= 256 -> token
        _ -> nil
      end

    cond do
      not Discovery.enabled?() ->
        conn |> send_resp(404, "") |> halt()

      not Discovery.authorized_token?(token) ->
        conn |> send_resp(401, "") |> halt()

      true ->
        conn
        |> assign(:discovery_token, token)
        |> Plug.Parsers.call(
          Plug.Parsers.init(
            parsers: [:json],
            pass: [],
            json_decoder: Jason,
            length: 131_072,
            read_length: 131_072
          )
        )
    end
  end

  def call(conn, _opts), do: conn
end
