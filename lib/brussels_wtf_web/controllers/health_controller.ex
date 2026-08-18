defmodule BrusselsWtfWeb.HealthController do
  use BrusselsWtfWeb, :controller

  def live(conn, _params), do: send_resp(conn, :no_content, "")
end
