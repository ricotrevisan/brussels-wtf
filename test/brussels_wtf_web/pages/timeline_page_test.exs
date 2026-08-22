defmodule BrusselsWtfWeb.TimelinePageTest do
  use BrusselsWtfWeb.ConnCase, async: true

  test "GET / renders the empty timeline", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Coming up"
    assert html =~ "Previously"
    assert html =~ "brussels.wtf"
  end
end
