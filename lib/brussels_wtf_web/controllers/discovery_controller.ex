defmodule BrusselsWtfWeb.DiscoveryController do
  use BrusselsWtfWeb, :controller
  alias BrusselsWtf.Discovery
  require Logger

  def claim(conn, params) when params == %{} do
    safely(conn, fn -> Discovery.claim(conn.assigns.discovery_token) end)
  end

  def claim(conn, _params), do: respond(conn, {:error, :invalid_request})

  def result(conn, %{"id" => id}) do
    safely(conn, fn -> Discovery.submit(id, conn.body_params, conn.assigns.discovery_token) end)
  end

  def fail(conn, %{"id" => id}) do
    safely(conn, fn -> Discovery.fail(id, conn.body_params, conn.assigns.discovery_token) end)
  end

  # Never let a storage exception render/log an Ash changeset containing evidence.
  defp safely(conn, operation) do
    respond(conn, operation.())
  rescue
    _ ->
      Logger.warning("private_discovery_request_failed")
      conn |> put_status(503) |> json(%{error: :unavailable})
  end

  defp respond(conn, {:ok, nil}), do: send_resp(conn, 204, "")
  defp respond(conn, {:ok, acknowledgment}), do: json(conn, acknowledgment)

  defp respond(conn, {:error, reason}) do
    status =
      case reason do
        :unauthorized -> 401
        :not_found -> 404
        reason when reason in [:stale_lease, :conflicting_result] -> 409
        _ -> 422
      end

    conn |> put_status(status) |> json(%{error: reason})
  end
end
