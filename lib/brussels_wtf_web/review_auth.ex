defmodule BrusselsWtfWeb.ReviewAuth do
  @moduledoc "Session authentication for the single MVP reviewer."

  import Plug.Conn

  alias BrusselsWtf.Review.Actor

  @session_actor_id "review_actor_id"
  @session_authenticated_at "review_authenticated_at"
  @session_credential_version "review_credential_version"

  def authenticate(username, password) when is_binary(username) and is_binary(password) do
    config = config()

    if secure_equal?(username, config[:username]) and secure_equal?(password, config[:password]) do
      {:ok, %Actor{id: config[:actor_id], role: :reviewer}}
    else
      {:error, :invalid_credentials}
    end
  end

  def authenticate(_, _), do: {:error, :invalid_credentials}

  def log_in(conn, %Actor{} = actor) do
    conn
    |> configure_session(renew: true)
    |> put_session(@session_actor_id, actor.id)
    |> put_session(@session_authenticated_at, System.system_time(:second))
    |> put_session(@session_credential_version, credential_version())
  end

  def log_out(conn), do: configure_session(conn, drop: true)

  def current_actor(conn) do
    with actor_id when is_binary(actor_id) <- get_session(conn, @session_actor_id),
         authenticated_at when is_integer(authenticated_at) <-
           get_session(conn, @session_authenticated_at),
         credential_version when is_binary(credential_version) <-
           get_session(conn, @session_credential_version),
         true <- session_current?(authenticated_at),
         true <- secure_equal?(actor_id, config()[:actor_id]),
         true <- secure_equal?(credential_version, credential_version()) do
      %Actor{id: actor_id, role: :reviewer}
    else
      _ -> nil
    end
  end

  defp session_current?(authenticated_at) do
    age = System.system_time(:second) - authenticated_at
    age >= 0 and age <= config()[:session_ttl_seconds]
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    Plug.Crypto.secure_compare(:crypto.hash(:sha256, left), :crypto.hash(:sha256, right))
  end

  defp secure_equal?(_, _), do: false

  defp credential_version do
    :crypto.hash(:sha256, config()[:password])
    |> Base.url_encode64(padding: false)
  end

  defp config, do: Application.fetch_env!(:brussels_wtf, :review_auth)
end
