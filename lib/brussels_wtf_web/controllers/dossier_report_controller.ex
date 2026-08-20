defmodule BrusselsWtfWeb.DossierReportController do
  use BrusselsWtfWeb, :controller

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.Dossiers

  def create(conn, %{"slug" => slug, "link_id" => link_id, "reason" => reason}) do
    reason = String.trim(reason)

    with true <- String.length(reason) >= 10,
         {:ok, %{status: :active} = dossier} <- Council.get_dossier(slug) do
      Dossiers.report_incorrect_link!(link_id, dossier.id, reason)

      conn
      |> put_flash(:info, "The dossier link report was sent for private review.")
      |> redirect(to: "/dossiers/#{slug}?lang=#{conn.assigns.locale}")
    else
      _ -> send_resp(conn, 422, "A valid reason and active dossier link are required")
    end
  rescue
    Ash.Error.Query.NotFound -> send_resp(conn, 404, "Not found")
    ArgumentError -> send_resp(conn, 404, "Not found")
  end

  def create(conn, _params), do: send_resp(conn, 422, "A report reason is required")
end
