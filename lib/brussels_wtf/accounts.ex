defmodule BrusselsWtf.Accounts do
  @moduledoc "Citizen-only authentication through single-use email magic links."
  use Ash.Domain, otp_app: :brussels_wtf
  require Ash.Query
  alias BrusselsWtf.Accounts.{Citizen, Session}

  resources do
    resource Citizen
    resource BrusselsWtf.Accounts.Token
    resource Session
  end

  def request_link(email, locale \\ "en")

  def request_link(email, _locale) when is_binary(email) do
    strategy = AshAuthentication.Info.strategy!(Citizen, :magic_link)

    _ =
      AshAuthentication.Strategy.action(strategy, :request, %{
        "email" => String.downcase(String.trim(email))
      })

    :ok
  rescue
    _ -> :ok
  end

  def request_link(_, _), do: :ok

  def consume(token) when is_binary(token) do
    strategy = AshAuthentication.Info.strategy!(Citizen, :magic_link)
    now = clock().utc_now()

    with {:ok, citizen} <-
           AshAuthentication.Strategy.action(strategy, :sign_in, %{"token" => token}),
         {:ok, citizen} <-
           citizen
           |> Ash.Changeset.for_update(:record_sign_in, %{last_sign_in_at: now})
           |> Ash.update(
             actor: %{id: citizen.id, principal: :citizen},
             authorize?: true,
             domain: __MODULE__
           ),
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
  rescue
    _ -> {:error, :invalid_or_expired}
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
           Ash.get(Citizen, session.citizen_id,
             actor: %{id: session.citizen_id, principal: :citizen},
             authorize?: true,
             domain: __MODULE__
           ),
         {:ok, _} <- update(session, :touch, %{last_active_at: now}) do
      {:ok, citizen}
    else
      _ -> {:error, :expired}
    end
  end

  def authenticate_session(_), do: {:error, :expired}

  def change_email(citizen, email) do
    with {:ok, changed} <-
           citizen
           |> Ash.Changeset.for_update(:change_email, %{
             email: String.downcase(String.trim(email))
           })
           |> Ash.update(
             actor: %{id: citizen.id, principal: :citizen},
             authorize?: true,
             domain: __MODULE__
           ) do
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

  defp clock, do: Application.fetch_env!(:brussels_wtf, :clock)
end
