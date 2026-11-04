defmodule BrusselsWtfWeb.SitemapController do
  use BrusselsWtfWeb, :controller

  def show(conn, _params) do
    case BrusselsWtfWeb.PublicSitemap.Cache.fetch() do
      {:ok, xml} ->
        conn
        |> put_resp_content_type("application/xml")
        |> put_resp_header("cache-control", "public, max-age=300")
        |> send_resp(200, xml)

      {:error, :unavailable} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> send_resp(503, "")
    end
  end
end
