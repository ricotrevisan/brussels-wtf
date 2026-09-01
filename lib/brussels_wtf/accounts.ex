defmodule BrusselsWtf.Accounts do
  @moduledoc "Citizen-only authentication through single-use email magic links."
  use Ash.Domain, otp_app: :brussels_wtf
  require Ash.Query
  alias BrusselsWtf.Accounts.{Citizen, MagicLink, Session}

  resources do
    resource Citizen
    resource MagicLink
    resource Session
  end

  def request_link(email, locale \\ "en")

  def request_link(email, locale) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()
    now = clock().utc_now()
    token = token()
    attrs = %{email: email, token_hash: hash(token), expires_at: DateTime.add(now, 15, :minute)}

    with {:ok, _} <- create(MagicLink, :issue, attrs),
         :ok <- mailer().deliver_magic_link(email, token, locale) do
      :ok
    else
      _ -> :ok
    end
  end

  def request_link(_, _), do: :ok

  def consume(token) when is_binary(token) do
    now = clock().utc_now()
    query = MagicLink |> Ash.Query.for_read(:by_hash, %{token_hash: hash(token)})

    with {:ok, link} when not is_nil(link) <-
           Ash.read_one(query, authorize?: true, domain: __MODULE__),
         :lt <- DateTime.compare(now, link.expires_at),
         {:ok, _} <- consume_once(link, now),
         {:ok, citizen} <- find_or_create(link.email, now),
         {:ok, session} <-
           create(Session, :open, %{
             citizen_id: citizen.id,
             last_active_at: now,
             expires_at: DateTime.add(now, 90, :day)
           }) do
      {:ok, citizen, session}
    else
      _ -> {:error, :invalid_or_expired}
    end
  end

  def consume(_), do: {:error, :invalid_or_expired}

  def authenticate_session(id) when is_binary(id) do
    now = clock().utc_now()

    with {:ok, session} <-
           Session
           |> Ash.Query.for_read(:by_id, %{id: id})
           |> Ash.read_one(authorize?: true, domain: __MODULE__),
         true <- not is_nil(session),
         :lt <- DateTime.compare(now, session.expires_at),
         true <- DateTime.compare(now, DateTime.add(session.last_active_at, 30, :day)) == :lt,
         {:ok, citizen} <-
           Ash.get(Citizen, session.citizen_id, authorize?: true, domain: __MODULE__),
         {:ok, _} <- update(session, :touch, %{last_active_at: now}) do
      {:ok, citizen}
    else
      _ -> {:error, :expired}
    end
  end

  def authenticate_session(_), do: {:error, :expired}

  def change_email(citizen, email) do
    with {:ok, changed} <-
           update(citizen, :change_email, %{email: String.downcase(String.trim(email))}) do
      revoke_sessions(citizen.id)
      {:ok, changed}
    end
  end

  def revoke_sessions(citizen_id) do
    Session
    |> Ash.Query.filter(citizen_id == ^citizen_id)
    |> Ash.read!(authorize?: false, domain: __MODULE__)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false, domain: __MODULE__))

    :ok
  end

  defp consume_once(link, now) do
    link
    |> Ash.Changeset.for_update(:consume, %{consumed_at: now})
    |> Ash.update(authorize?: true, domain: __MODULE__)
  end

  defp find_or_create(email, now) do
    case Citizen
         |> Ash.Query.for_read(:by_email, %{email: email})
         |> Ash.read_one(authorize?: true, domain: __MODULE__) do
      {:ok, nil} -> create(Citizen, :register, %{email: email, last_sign_in_at: now})
      {:ok, c} -> update(c, :sign_in, %{last_sign_in_at: now})
      error -> error
    end
  end

  defp create(resource, action, attrs),
    do:
      resource
      |> Ash.Changeset.for_create(action, attrs)
      |> Ash.create(authorize?: true, domain: __MODULE__)

  defp update(record, action, attrs),
    do:
      record
      |> Ash.Changeset.for_update(action, attrs)
      |> Ash.update(authorize?: true, domain: __MODULE__)

  defp token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  defp hash(v), do: :crypto.hash(:sha256, v)
  defp clock, do: Application.fetch_env!(:brussels_wtf, :clock)
  defp mailer, do: Application.fetch_env!(:brussels_wtf, :citizen_mailer)
end
