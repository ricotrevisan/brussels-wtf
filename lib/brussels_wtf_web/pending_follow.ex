defmodule BrusselsWtfWeb.PendingFollow do
  @moduledoc """
  Remembers a follow that a signed-out reader clicked, so it completes after
  they sign in from the same browser. It lives in the signed session cookie and
  lapses after 30 minutes, so an abandoned click never surfaces days later.
  """
  import Plug.Conn

  @key :pending_follow
  @ttl_seconds 30 * 60
  @types ~w(dossier person legal_entity commune)

  # Real identifiers are short; the cap keeps the cookie under its 4 KB limit.
  def put(conn, type, identifier)
      when type in @types and is_binary(identifier) and identifier != "" and
             byte_size(identifier) <= 256 do
    put_session(conn, @key, %{"type" => type, "identifier" => identifier, "at" => now()})
  end

  def put(conn, _type, _identifier), do: conn

  def pending?(conn), do: not is_nil(current(conn))

  @doc "Returns the conn without the pending follow, and the follow as `{type, identifier}` or nil."
  def take(conn), do: {delete_session(conn, @key), current(conn)}

  defp current(conn) do
    case get_session(conn, @key) do
      %{"type" => type, "identifier" => identifier, "at" => at}
      when type in @types and is_integer(at) ->
        if now() - at <= @ttl_seconds,
          do: {String.to_existing_atom(type), identifier},
          else: nil

      _ ->
        nil
    end
  end

  defp now, do: Application.fetch_env!(:brussels_wtf, :clock).utc_now() |> DateTime.to_unix()
end
