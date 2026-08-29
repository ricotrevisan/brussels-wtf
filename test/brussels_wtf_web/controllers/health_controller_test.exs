defmodule BrusselsWtfWeb.HealthControllerTest do
  use BrusselsWtfWeb.ConnCase, async: false

  defmodule Ready do
    def status, do: :ok
  end

  defmodule PendingMigrations do
    def status, do: {:error, :pending_migrations}
  end

  defmodule ArchiveUnavailable do
    def status, do: {:error, :archive_unavailable}
  end

  setup do
    previous = Application.get_env(:brussels_wtf, :readiness)

    on_exit(fn ->
      if previous do
        Application.put_env(:brussels_wtf, :readiness, previous)
      else
        Application.delete_env(:brussels_wtf, :readiness)
      end
    end)
  end

  test "liveness stays cheap and unauthenticated", %{conn: conn} do
    Application.put_env(:brussels_wtf, :readiness, ArchiveUnavailable)
    conn = get(conn, ~p"/health/live")

    assert response(conn, 204) == ""
    assert get_resp_header(conn, "set-cookie") == []
  end

  test "version exposes the immutable release identifier without a session", %{conn: conn} do
    previous = Application.get_env(:brussels_wtf, :release_sha)
    Application.put_env(:brussels_wtf, :release_sha, "1d0f92a")

    on_exit(fn ->
      if previous do
        Application.put_env(:brussels_wtf, :release_sha, previous)
      else
        Application.delete_env(:brussels_wtf, :release_sha)
      end
    end)

    conn = get(conn, ~p"/health/version")

    assert json_response(conn, 200) == %{"release" => "1d0f92a"}
    assert get_resp_header(conn, "set-cookie") == []
  end

  test "readiness succeeds only when its database and archive checks pass", %{conn: conn} do
    Application.put_env(:brussels_wtf, :readiness, Ready)
    conn = get(conn, ~p"/health/ready")

    assert response(conn, 204) == ""
    assert get_resp_header(conn, "set-cookie") == []
  end

  test "readiness fails safely when migrations are pending", %{conn: conn} do
    Application.put_env(:brussels_wtf, :readiness, PendingMigrations)
    conn = get(conn, ~p"/health/ready")

    assert response(conn, 503) == ""
  end

  test "readiness fails safely when the archive is inaccessible", %{conn: conn} do
    Application.put_env(:brussels_wtf, :readiness, ArchiveUnavailable)
    conn = get(conn, ~p"/health/ready")

    assert response(conn, 503) == ""
  end
end
