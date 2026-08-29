defmodule BrusselsWtfWeb.HealthController do
  use BrusselsWtfWeb, :controller

  def live(conn, _params), do: send_resp(conn, :no_content, "")

  def version(conn, _params) do
    json(conn, %{release: Application.fetch_env!(:brussels_wtf, :release_sha)})
  end

  def ready(conn, _params) do
    case readiness().status() do
      :ok -> send_resp(conn, :no_content, "")
      {:error, _reason} -> send_resp(conn, :service_unavailable, "")
    end
  end

  defp readiness do
    Application.fetch_env!(:brussels_wtf, :readiness)
  end
end
