defmodule BrusselsWtfWeb.HealthControllerTest do
  use BrusselsWtfWeb.ConnCase, async: true

  test "liveness stays cheap and unauthenticated", %{conn: conn} do
    conn = get(conn, ~p"/health/live")

    assert response(conn, 204) == ""
    assert get_resp_header(conn, "set-cookie") == []
  end
end
