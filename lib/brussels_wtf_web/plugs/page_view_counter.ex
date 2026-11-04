defmodule BrusselsWtfWeb.Plugs.PageViewCounter do
  @moduledoc """
  Counts a successful public page view as a daily total.

  The user agent and Referer are read here and only the route pattern, locale
  and referrer host ever leave this module. Any failure is swallowed: a counter
  problem must never reach the reader.
  """

  import Plug.Conn

  alias BrusselsWtf.Readership
  alias BrusselsWtf.Readership.PageViewBuffer

  @behaviour Plug

  @public_routes ~w(
    /
    /about
    /coverage
    /coverage/coming-up
    /coverage/awaiting-outcome
    /coverage/decisions
    /coverage/contested-votes
    /mandates
    /meetings/:commune/:municipal_id
    /dossiers/:slug
    /companies/:enterprise_number
    /people/:id
  )
  @locales ~w(fr nl en)
  @obvious_automation ~r/bot|crawl|spider|slurp|scrape|preview|headless|lighthouse|pingdom|uptime|monitor|facebookexternalhit|embedly|curl|wget|httpie|python|java\/|go-http|okhttp|axios|node-fetch|libwww|ruby|perl|php\//i
  @public_hostname ~r/\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: register_before_send(conn, &count_safely/1)

  defp count_safely(conn) do
    try do
      if key = bucket(conn), do: PageViewBuffer.record(key)
    rescue
      _error -> :ok
    catch
      _kind, _reason -> :ok
    end

    conn
  end

  defp bucket(%{method: "GET", status: 200, assigns: %{locale: locale}} = conn)
       when locale in @locales do
    with true <- human_page_view?(conn),
         route when route in @public_routes <- route_pattern(conn) do
      {BrusselsWtfWeb.MeetingTime.today(), route, locale, referrer_host(conn)}
    else
      _ -> nil
    end
  end

  defp bucket(_conn), do: nil

  defp human_page_view?(conn) do
    agent = header(conn, "user-agent")

    is_binary(agent) and agent != "" and not Regex.match?(@obvious_automation, agent) and
      not prefetch?(conn)
  end

  defp prefetch?(conn) do
    Enum.any?(~w(sec-purpose purpose x-moz), fn name ->
      case header(conn, name) do
        nil -> false
        value -> String.contains?(String.downcase(value), "prefetch")
      end
    end)
  end

  defp route_pattern(conn) do
    case Phoenix.Router.route_info(
           conn.private.phoenix_router,
           "GET",
           conn.path_info,
           conn.host
         ) do
      %{route: route} -> route
      :error -> nil
    end
  end

  defp referrer_host(conn) do
    with referrer when is_binary(referrer) <- header(conn, "referer"),
         true <- String.valid?(referrer),
         {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] <-
           URI.new(referrer),
         true <- is_binary(host),
         normalized = host |> String.downcase() |> String.replace_prefix("www.", ""),
         true <- byte_size(normalized) <= 253,
         true <- Regex.match?(@public_hostname, normalized),
         false <- normalized in own_hosts(conn) do
      normalized
    else
      _ -> Readership.direct_referrer()
    end
  end

  defp own_hosts(conn) do
    Enum.map([conn.host, BrusselsWtfWeb.Endpoint.host()], fn host ->
      host |> String.downcase() |> String.replace_prefix("www.", "")
    end)
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()
end
