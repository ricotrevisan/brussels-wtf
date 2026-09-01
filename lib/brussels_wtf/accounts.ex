defmodule BrusselsWtf.Accounts do
  @moduledoc "Citizen-only authentication through single-use email magic links."
  use Ash.Domain, otp_app: :brussels_wtf
  require Ash.Query
  require Logger
  alias BrusselsWtf.Accounts.{Citizen, Session}

  resources do
    resource Citizen
    resource BrusselsWtf.Accounts.Token
    resource BrusselsWtf.Accounts.OutstandingMagicLink
    resource Session
  end

  def request_link(email, locale \\ "en")

  def request_link(email, locale) when is_binary(email) do
    strategy = AshAuthentication.Info.strategy!(Citizen, :magic_link)

    previous_locale = Process.get(:citizen_magic_link_locale)
    Process.put(:citizen_magic_link_locale, normalize_locale(locale))

    try do
      _ =
        AshAuthentication.Strategy.action(strategy, :request, %{
          "email" => String.downcase(String.trim(email))
        })
    after
      if previous_locale,
        do: Process.put(:citizen_magic_link_locale, previous_locale),
        else: Process.delete(:citizen_magic_link_locale)
    end

    Logger.warning("citizen_magic_link_requested")
    :ok
  rescue
    _ -> :ok
  end

  def request_link(_, _), do: :ok

  defp normalize_locale(locale) when locale in ["fr", "nl", "en"], do: locale
  defp normalize_locale(_), do: "en"

  def consume(token) when is_binary(token) do
    strategy = AshAuthentication.Info.strategy!(Citizen, :magic_link)
    now = clock().utc_now()

    with {:ok, claims} <- Joken.peek_claims(token),
         {:ok, outstanding} <- outstanding_magic_link(claims["jti"]),
         {:ok, citizen} <-
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
           Session
           |> Ash.Changeset.for_create(:open, %{
             citizen_id: citizen.id,
             last_active_at: now,
             expires_at: DateTime.add(now, 90, :day)
           })
           |> Ash.create(actor: %{principal: :system}, authorize?: true, domain: __MODULE__) do
      Ash.destroy!(outstanding,
        action: :remove,
        actor: %{principal: :system},
        authorize?: true,
        domain: __MODULE__
      )

      Logger.warning("citizen_magic_link_consumed")
      {:ok, citizen, session}
    else
      _ ->
        Logger.warning("citizen_magic_link_rejected")
        {:error, :invalid_or_expired}
    end
  rescue
    _ ->
      Logger.warning("citizen_magic_link_rejected")
      {:error, :invalid_or_expired}
  end

  def consume(_), do: {:error, :invalid_or_expired}

  def authenticate_session(id) when is_binary(id) do
    now = clock().utc_now()

    with {:ok, session} <-
           Session
           |> Ash.Query.for_read(:by_id, %{id: id})
           |> Ash.read_one(actor: %{principal: :system}, authorize?: true, domain: __MODULE__),
         true <- not is_nil(session),
         :lt <- DateTime.compare(now, session.expires_at),
         true <- DateTime.compare(now, DateTime.add(session.last_active_at, 30, :day)) == :lt,
         {:ok, citizen} <-
           Ash.get(Citizen, session.citizen_id,
             actor: %{id: session.citizen_id, principal: :citizen},
             authorize?: true,
             domain: __MODULE__
           ),
         {:ok, _} <-
           session
           |> Ash.Changeset.for_update(:touch, %{last_active_at: now})
           |> Ash.update(
             actor: %{id: session.citizen_id, principal: :citizen},
             authorize?: true,
             domain: __MODULE__
           ) do
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
      revoke_outstanding_magic_links(citizen.email)
      strategy = AshAuthentication.Info.strategy!(Citizen, :log_out_everywhere)

      _ =
        AshAuthentication.Strategy.action(strategy, :log_out_everywhere, %{
          "user_id" => citizen.id
        })

      Logger.warning("citizen_email_changed_sessions_revoked")
      {:ok, changed}
    end
  end

  defp outstanding_magic_link(jti) when is_binary(jti) do
    actor = %{principal: :system}

    case BrusselsWtf.Accounts.OutstandingMagicLink
         |> Ash.Query.filter(jti == ^jti)
         |> Ash.read_one(actor: actor, authorize?: true, domain: __MODULE__) do
      {:ok, nil} -> {:error, :not_found}
      result -> result
    end
  end

  defp outstanding_magic_link(_), do: {:error, :not_found}

  def record_outstanding_magic_link(email, token) do
    with {:ok, claims} <- Joken.peek_claims(token) do
      BrusselsWtf.Accounts.OutstandingMagicLink
      |> Ash.Changeset.for_create(:record, %{
        email_hash: email_hash(email),
        jti: claims["jti"],
        subject: claims["sub"]
      })
      |> Ash.create(actor: %{principal: :system}, authorize?: true, domain: __MODULE__)
      |> case do
        {:ok, _} -> :ok
        _ -> :ok
      end
    else
      _ -> :ok
    end
  end

  defp revoke_outstanding_magic_links(email) do
    actor = %{principal: :system}

    BrusselsWtf.Accounts.OutstandingMagicLink
    |> Ash.Query.filter(email_hash == ^email_hash(email))
    |> Ash.read!(actor: actor, authorize?: true, domain: __MODULE__)
    |> Enum.each(fn link ->
      case BrusselsWtf.Accounts.Token
           |> Ash.Query.for_read(:get_token, %{jti: link.jti, purpose: "magic_link"})
           |> Ash.read_one(authorize?: false, domain: __MODULE__) do
        {:ok, token_record} when not is_nil(token_record) ->
          Ash.destroy!(token_record,
            action: :revoke_stored,
            authorize?: false,
            domain: __MODULE__
          )

        _ ->
          :ok
      end

      Ash.destroy!(link, action: :remove, actor: actor, authorize?: true, domain: __MODULE__)
    end)
  end

  defp email_hash(email), do: :crypto.hash(:sha256, String.downcase(to_string(email)))

  def revoke_sessions(citizen_id) do
    Session
    |> Ash.Query.filter(citizen_id == ^citizen_id)
    |> Ash.read!(actor: %{principal: :system}, authorize?: true, domain: __MODULE__)
    |> Enum.each(
      &Ash.destroy!(&1, actor: %{principal: :system}, authorize?: true, domain: __MODULE__)
    )

    :ok
  end

  defp clock, do: Application.fetch_env!(:brussels_wtf, :clock)
end
