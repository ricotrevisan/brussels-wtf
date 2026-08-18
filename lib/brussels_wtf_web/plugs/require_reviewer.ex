defmodule BrusselsWtfWeb.Plugs.RequireReviewer do
  @moduledoc false

  import Phoenix.Controller
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case BrusselsWtfWeb.ReviewAuth.current_actor(conn) do
      nil ->
        conn
        |> redirect(to: "/review/login")
        |> halt()

      actor ->
        assign(conn, :current_review_actor, actor)
    end
  end
end
