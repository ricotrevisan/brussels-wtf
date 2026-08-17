defmodule BrusselsWtfWeb.Locale do
  @moduledoc """
  Resolves one complete public locale before rendering.

  Precedence is an explicit valid `lang`, the persisted reader cookie,
  `Accept-Language` on first visit, then English. Locale-dependent responses
  are private and vary on both reader inputs so a shared cache cannot mix
  languages.
  """

  import Plug.Conn

  @behaviour Plug
  @public_locales ~w(fr nl en)
  @cookie "brussels_wtf_locale"
  @year 31_536_000

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = conn |> fetch_query_params() |> fetch_cookies()
    explicit = normalize(conn.query_params["lang"])

    locale =
      explicit ||
        normalize(conn.cookies[@cookie]) ||
        accept_language(conn) ||
        "en"

    conn
    |> assign(:locale, locale)
    |> put_resp_header("content-language", locale)
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("vary", "Accept-Language, Cookie")
    |> persist_explicit(explicit)
  end

  @spec resolve(Plug.Conn.t(), map()) :: String.t()
  def resolve(%Plug.Conn{assigns: %{locale: locale}}, _params), do: locale

  def resolve(conn, params) when is_map(params),
    do: normalize(params["lang"]) || accept_language(conn) || "en"

  @spec resolve(map()) :: String.t()
  def resolve(params) when is_map(params), do: normalize(params["lang"]) || "en"

  defp persist_explicit(conn, nil), do: conn

  defp persist_explicit(conn, locale) do
    put_resp_cookie(conn, @cookie, locale,
      max_age: @year,
      same_site: "Lax",
      http_only: false,
      path: "/"
    )
  end

  defp accept_language(conn) do
    conn
    |> get_req_header("accept-language")
    |> List.first()
    |> parse_accept_language()
  end

  defp parse_accept_language(nil), do: nil

  defp parse_accept_language(header) do
    header
    |> String.split(",")
    |> Enum.with_index()
    |> Enum.map(fn {range, index} ->
      [tag | params] = range |> String.trim() |> String.split(";")

      quality =
        Enum.find_value(params, 1.0, fn param ->
          case String.split(String.trim(param), "=", parts: 2) do
            ["q", value] ->
              case Float.parse(value) do
                {q, ""} when q >= 0.0 and q <= 1.0 -> q
                _ -> 0.0
              end

            _ ->
              nil
          end
        end)

      {quality, index, normalize(tag)}
    end)
    |> Enum.filter(fn {quality, _index, locale} -> quality > 0 and locale in @public_locales end)
    |> Enum.sort_by(fn {quality, index, _locale} -> {-quality, index} end)
    |> case do
      [{_quality, _index, locale} | _] -> locale
      [] -> nil
    end
  end

  defp normalize(lang) when is_binary(lang) do
    tag = lang |> String.trim() |> String.replace("_", "-") |> String.downcase()

    if Regex.match?(~r/^[a-z]{2,3}(?:-[a-z0-9]{2,8})*$/, tag) do
      case String.split(tag, "-", parts: 2) do
        [locale | _] when locale in @public_locales -> locale
        _ -> nil
      end
    end
  end

  defp normalize(_), do: nil
end
