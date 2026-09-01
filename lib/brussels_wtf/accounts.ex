defmodule BrusselsWtf.Accounts do
  @moduledoc "Citizen-only authentication through single-use email magic links."
  use Ash.Domain, otp_app: :brussels_wtf
  require Ash.Query
  require Logger
  alias BrusselsWtf.Accounts.{Citizen, OutstandingMagicLink, Session}

  resources do
    resource Citizen
    resource BrusselsWtf.Accounts.Token
    resource BrusselsWtf.Accounts.OutstandingMagicLink
    resource Session
  end

  def request_link(email, locale \\ "en")

  def request_link(email, locale) when is_binary(email) do
    strategy = AshAuthentication.Info.strategy!(Citizen, :magic_link)
    cleanup_expired_magic_links()

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

  @doc "Changes email only if every old authentication capability is revoked atomically."
  def change_email(%Citizen{} = citizen, email) when is_binary(email) do
    security_transaction(fn ->
      :ok = maybe_fail(:sessions)
      :ok = revoke_sessions_checked(citizen.id)
      :ok = maybe_fail(:outstanding_links)
      :ok = revoke_outstanding_magic_links_checked(citizen.email)
      :ok = maybe_fail(:authentication_tokens)
      :ok = revoke_authentication_tokens_checked(citizen)
      :ok = maybe_fail(:email)

      citizen
      |> Ash.Changeset.for_update(:apply_email_change, %{
        email: String.downcase(String.trim(email))
      })
      |> Ash.update(
        actor: %{principal: :system},
        authorize?: true,
        domain: __MODULE__,
        return_notifications?: true
      )
      |> checked_value()
    end)
    |> case do
      {:ok, changed} ->
        Logger.warning("citizen_email_changed_sessions_revoked")
        {:ok, changed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Delete all citizen state atomically. Public/unlisted ownership must be explicitly resolved."
  def delete_citizen(%Citizen{} = citizen, resolutions \\ %{}) do
    operation_id = Ash.UUID.generate()

    BrusselsWtf.Repo.transaction(fn ->
      sql!("SELECT set_config('brussels_wtf.allow_collection_transfer', 'on', true)", [])

      {:ok, %{rows: collections}} =
        BrusselsWtf.Repo.query(
          "SELECT id, visibility FROM follow_collections WHERE owner_citizen_id=$1 FOR UPDATE",
          [citizen.id]
        )

      Enum.each(collections, fn [id, visibility] ->
        choice = Map.get(resolutions, id) || Map.get(resolutions, to_string(id))

        cond do
          visibility == "private" ->
            sql!("DELETE FROM follow_collections WHERE id=$1", [id])

          choice == :delete ->
            sql!("DELETE FROM follow_collections WHERE id=$1", [id])

          match?({:transfer, _, true}, choice) ->
            {:transfer, recipient_id, true} = choice
            if recipient_id == citizen.id, do: BrusselsWtf.Repo.rollback(:invalid_transfer)

            case BrusselsWtf.Repo.query(
                   "UPDATE follow_collections SET owner_citizen_id=$1 WHERE id=$2 AND owner_citizen_id=$3",
                   [recipient_id, id, citizen.id]
                 ) do
              {:ok, %{num_rows: 1}} -> :ok
              _ -> BrusselsWtf.Repo.rollback(:unsafe_transfer)
            end

          true ->
            BrusselsWtf.Repo.rollback(:owned_collection_requires_resolution)
        end
      end)

      sql!("DELETE FROM follow_collection_grants WHERE citizen_id=$1", [citizen.id])
      sql!("DELETE FROM citizen_feed_updates WHERE citizen_id=$1", [citizen.id])
      sql!("DELETE FROM citizen_follows WHERE citizen_id=$1", [citizen.id])
      sql!("DELETE FROM citizen_retention_warnings WHERE citizen_id=$1", [citizen.id])

      case delete_account(citizen) do
        {:ok, :ok} -> :ok
        {:error, reason} -> BrusselsWtf.Repo.rollback(reason)
      end

      {:ok, _} =
        BrusselsWtf.Follow.DeletionAudit
        |> Ash.Changeset.for_create(:record, %{
          operation_id: operation_id,
          completed_at: clock().utc_now()
        })
        |> Ash.create(actor: %{principal: :system}, authorize?: true, domain: BrusselsWtf.Follow)

      operation_id
    end)
  end

  def run_inactivity_retention(now \\ clock().utc_now(), resolutions \\ %{}) do
    actor = %{principal: :system}
    citizens = Citizen |> Ash.read!(actor: actor, authorize?: false, domain: __MODULE__)

    Enum.map(citizens, fn citizen ->
      deletion_at = DateTime.add(citizen.last_sign_in_at || citizen.inserted_at, 183, :day)
      days = DateTime.diff(deletion_at, now, :day)

      cond do
        DateTime.compare(now, deletion_at) != :lt ->
          delete_citizen(citizen, Map.get(resolutions, citizen.id, %{}))

        days <= 7 ->
          record_warning(citizen.id, 7, now)

        days <= 30 ->
          record_warning(citizen.id, 30, now)

        true ->
          :ok
      end
    end)
  end

  defp record_warning(citizen_id, days, now) do
    BrusselsWtf.Follow.RetentionWarning
    |> Ash.Changeset.for_create(:record, %{
      citizen_id: citizen_id,
      days_before_deletion: days,
      warned_at: now
    })
    |> Ash.create(actor: %{principal: :system}, authorize?: true, domain: BrusselsWtf.Follow)
  end

  defp sql!(statement, params) do
    case BrusselsWtf.Repo.query(statement, params) do
      {:ok, _} -> :ok
      {:error, reason} -> BrusselsWtf.Repo.rollback(reason)
    end
  end

  @doc "Deletes an account and all authentication state in one transaction."
  def delete_account(%Citizen{} = citizen) do
    security_transaction(fn ->
      outstanding_jtis = outstanding_magic_link_jtis_checked(citizen.email)
      :ok = revoke_sessions_checked(citizen.id)
      :ok = revoke_outstanding_magic_links_checked(citizen.email)
      :ok = purge_authentication_tokens_checked(citizen, outstanding_jtis)

      citizen
      |> Ash.destroy(
        action: :delete_account,
        actor: %{principal: :system},
        authorize?: true,
        domain: __MODULE__,
        return_notifications?: true
      )
      |> checked_ok()

      :ok
    end)
  end

  defp security_transaction(fun) do
    previous = Process.get(:account_security_notifications)
    Process.put(:account_security_notifications, [])

    {result, notifications} =
      try do
        result =
          BrusselsWtf.Repo.transaction(fn ->
            try do
              fun.()
            catch
              {:security_failure, reason} -> BrusselsWtf.Repo.rollback(reason)
            end
          end)

        {result, Process.get(:account_security_notifications, []) |> Enum.reverse()}
      after
        if previous,
          do: Process.put(:account_security_notifications, previous),
          else: Process.delete(:account_security_notifications)
      end

    case result do
      {:ok, value} ->
        Ash.Notifier.notify(notifications)
        {:ok, value}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_notifications(notifications) do
    Process.put(
      :account_security_notifications,
      Enum.reverse(notifications) ++ Process.get(:account_security_notifications, [])
    )
  end

  defp maybe_fail(stage) do
    case Application.get_env(:brussels_wtf, :account_security_failure) do
      ^stage -> throw({:security_failure, {:injected_failure, stage}})
      fun when is_function(fun, 1) -> checked_ok(fun.(stage))
      _ -> :ok
    end
  end

  defp checked_value({:ok, value, notifications}) do
    collect_notifications(notifications)
    value
  end

  defp checked_value({:ok, value}), do: value
  defp checked_value({:error, reason}), do: throw({:security_failure, reason})
  defp checked_ok(:ok), do: :ok

  defp checked_ok({:ok, _value, notifications}) do
    collect_notifications(notifications)
    :ok
  end

  defp checked_ok({:ok, notifications}) when is_list(notifications) do
    collect_notifications(notifications)
    :ok
  end

  defp checked_ok({:ok, _}), do: :ok
  defp checked_ok({:error, reason}), do: throw({:security_failure, reason})
  defp checked_ok(other), do: throw({:security_failure, {:unexpected_result, other}})

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
        subject: claims["sub"],
        expires_at: DateTime.from_unix!(claims["exp"])
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

  defp revoke_outstanding_magic_links_checked(email) do
    actor = %{principal: :system}

    links =
      OutstandingMagicLink
      |> Ash.Query.filter(email_hash == ^email_hash(email))
      |> Ash.read(actor: actor, authorize?: true, domain: __MODULE__)
      |> checked_value()

    Enum.each(links, fn link ->
      OutstandingMagicLink
      |> Ash.get(link.id, actor: actor, authorize?: true, domain: __MODULE__)
      |> checked_value()
      |> Ash.destroy(
        action: :remove,
        actor: actor,
        authorize?: true,
        domain: __MODULE__,
        return_notifications?: true
      )
      |> checked_ok()
    end)

    :ok
  end

  defp revoke_authentication_tokens_checked(citizen) do
    strategy = AshAuthentication.Info.strategy!(Citizen, :log_out_everywhere)

    AshAuthentication.Strategy.action(strategy, :log_out_everywhere, %{"user" => citizen})
    |> checked_ok()
  end

  defp outstanding_magic_link_jtis_checked(email) do
    OutstandingMagicLink
    |> Ash.Query.filter(email_hash == ^email_hash(email))
    |> Ash.read(actor: %{principal: :system}, authorize?: true, domain: __MODULE__)
    |> checked_value()
    |> Enum.map(& &1.jti)
  end

  defp purge_authentication_tokens_checked(citizen, outstanding_jtis) do
    case BrusselsWtf.Repo.query(
           "DELETE FROM citizen_authentication_tokens WHERE subject LIKE $1 OR jti = ANY($2)",
           ["%" <> citizen.id <> "%", outstanding_jtis]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> throw({:security_failure, reason})
    end
  end

  defp email_hash(email) do
    key = Application.fetch_env!(:brussels_wtf, :citizen_token_signing_secret)

    :crypto.mac(
      :hmac,
      :sha256,
      key,
      "outstanding-magic-link:" <> String.downcase(to_string(email))
    )
  end

  def cleanup_expired_magic_links do
    now = clock().utc_now()
    actor = %{principal: :system}

    OutstandingMagicLink
    |> Ash.Query.filter(expires_at <= ^now)
    |> Ash.read!(actor: actor, authorize?: true, domain: __MODULE__)
    |> Enum.each(
      &Ash.destroy!(&1, action: :remove, actor: actor, authorize?: true, domain: __MODULE__)
    )

    :ok
  end

  def revoke_sessions(citizen_id), do: revoke_sessions_checked(citizen_id)

  defp revoke_sessions_checked(citizen_id) do
    sessions =
      Session
      |> Ash.Query.filter(citizen_id == ^citizen_id)
      |> Ash.read(actor: %{principal: :system}, authorize?: true, domain: __MODULE__)
      |> checked_value()

    Enum.each(sessions, fn session ->
      session
      |> Ash.destroy(
        actor: %{principal: :system},
        authorize?: true,
        domain: __MODULE__,
        return_notifications?: true
      )
      |> checked_ok()
    end)

    :ok
  end

  defp clock, do: Application.fetch_env!(:brussels_wtf, :clock)
end
