defmodule BrusselsWtfWeb.ReviewArtifactController do
  use BrusselsWtfWeb, :controller

  def source_version(conn, %{"id" => id, "token" => token}) do
    with :ok <- BrusselsWtfWeb.ReviewPreview.verify(token, "source-version", id),
         {:ok, version} <- BrusselsWtf.Ingestion.get_source_version(id),
         :ok <- source_preview_allowed(version),
         {:ok, bytes} <- BrusselsWtf.Archive.get(version.object_key),
         true <- BrusselsWtf.Digest.sha256(bytes) == version.sha256 do
      private_response(conn, version.media_type, "source-#{version.sha256}", bytes)
    else
      {:error, :source_too_large} ->
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_content_type("text/plain")
        |> send_resp(
          413,
          "Source exceeds the private preview limit; use the official source link."
        )

      _ ->
        send_resp(conn, 404, "Not found")
    end
  end

  def source_version(conn, _params), do: send_resp(conn, 404, "Not found")

  def derived_artifact(conn, %{"id" => id, "token" => token}) do
    with :ok <- BrusselsWtfWeb.ReviewPreview.verify(token, "derived-artifact", id),
         {:ok, artifact} <- BrusselsWtf.Ingestion.get_derived_artifact(id),
         {:ok, bytes} <- BrusselsWtf.Archive.get(artifact.object_key),
         true <- BrusselsWtf.Digest.sha256(bytes) == artifact.output_sha256 do
      private_response(
        conn,
        artifact.media_type,
        "#{artifact.output_kind}-#{artifact.output_sha256}",
        bytes
      )
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  def derived_artifact(conn, _params), do: send_resp(conn, 404, "Not found")

  defp source_preview_allowed(version) do
    if BrusselsWtf.Ingestion.SourceLimits.processing_allowed?(version),
      do: :ok,
      else: {:error, :source_too_large}
  end

  defp private_response(conn, media_type, filename, bytes) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
    |> put_resp_header("content-disposition", ~s(inline; filename="#{filename}"))
    |> put_resp_content_type(media_type)
    |> send_resp(200, bytes)
  end
end
