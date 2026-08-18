defmodule BrusselsWtfWeb.ReviewArtifactController do
  use BrusselsWtfWeb, :controller

  def show(conn, %{"id" => id, "token" => token}) do
    with {:ok, ^id} <- BrusselsWtfWeb.ReviewPreview.verify(token),
         {:ok, version} <- BrusselsWtf.Ingestion.get_source_version(id),
         {:ok, bytes} <- BrusselsWtf.Archive.get(version.object_key) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_resp_header("content-disposition", ~s(inline; filename="source-#{version.sha256}"))
      |> put_resp_content_type(version.media_type)
      |> send_resp(200, bytes)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  def show(conn, _params), do: send_resp(conn, 404, "Not found")
end
