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

  def owned_collections(citizen), do: BrusselsWtf.Follow.owner_collections(citizen)

  @doc "Delete all citizen state atomically. Public/unlisted ownership must be explicitly resolved."
  def delete_citizen(%Citizen{} = citizen, resolutions \\ %{}) do
    operation_id = Map.get(resolutions, :operation_id, Ash.UUID.generate())
    actor = %{principal: :system}

    case completed_deletion(operation_id, actor) do
      true ->
        {:ok, operation_id}

      false ->
        security_transaction(fn ->
          :ok = maybe_fail(:owned_collections)

          collections = BrusselsWtf.Follow.owner_collections(citizen) |> checked_value()

          Enum.each(collections, fn collection ->
            choice =
              Map.get(resolutions, collection.id) ||
                Map.get(resolutions, to_string(collection.id))

            if collection.visibility != :private and choice != :delete do
              throw({:security_failure, :owned_collection_requires_resolution})
            end

            :ok =
              maybe_fail(
                if(collection.visibility == :private,
                  do: :private_collections,
                  else: :selected_collections
                )
              )

            destroy_record_checked(collection, :delete_for_account, actor, BrusselsWtf.Follow)
          end)

          :ok = maybe_fail(:transfer_offers)

          destroy_follow_rows(
            BrusselsWtf.Follow.CollectionTransferOffer,
            :delete_for_account,
            citizen.id
          )

          :ok = maybe_fail(:grants_created)
          :ok = maybe_fail(:grants_received)
          destroy_follow_rows(BrusselsWtf.Follow.CollectionGrant, :delete_for_account, citizen.id)
          :ok = maybe_fail(:feed_updates)
          :ok = maybe_fail(:feed_read_state)
          destroy_follow_rows(BrusselsWtf.Follow.FeedUpdate, :delete_for_account, citizen.id)
          :ok = maybe_fail(:follows)
          destroy_follow_rows(BrusselsWtf.Follow.CitizenFollow, :delete_for_account, citizen.id)
          :ok = maybe_fail(:warnings)

          destroy_follow_rows(
            BrusselsWtf.Follow.RetentionWarning,
            :delete_for_account,
            citizen.id
          )

          delete_account_steps(citizen)
          :ok = maybe_fail(:audit)

          BrusselsWtf.Follow.DeletionAudit
          |> Ash.Changeset.for_create(:record, %{
            operation_id: operation_id,
            completed_at: clock().utc_now(),
            reason: Map.get(resolutions, :reason, :citizen_request)
          })
          |> Ash.create(
            actor: actor,
            authorize?: true,
            domain: BrusselsWtf.Follow,
            return_notifications?: true
          )
          |> checked_value()

          :ok = maybe_fail(:notification_collection)
          operation_id
        end)
    end
  end

  defp completed_deletion(operation_id, actor) do
    BrusselsWtf.Follow.DeletionAudit
    |> Ash.Query.filter(operation_id == ^operation_id)
    |> Ash.exists?(actor: actor, authorize?: true, domain: BrusselsWtf.Follow)
  end

  defp destroy_follow_rows(resource, action, citizen_id) do
    actor = %{principal: :system}

    resource
    |> Ash.Query.for_read(:for_account_deletion, %{citizen_id: citizen_id}, actor: actor)
    |> Ash.read(actor: actor, authorize?: true, domain: BrusselsWtf.Follow)
    |> checked_value()
    |> Enum.each(
      &destroy_record_checked(&1, action, actor, BrusselsWtf.Follow, %{citizen_id: citizen_id})
    )

    :ok
  end

  defp destroy_record_checked(record, action, actor, domain, arguments \\ %{}) do
    record
    |> Ash.Changeset.for_destroy(action, arguments, actor: actor)
    |> Ash.destroy(
      actor: actor,
      authorize?: true,
      domain: domain,
      return_notifications?: true
    )
    |> checked_ok()
  end

  @doc "Returns localized on-site warning data without recording account activity."
  def inactivity_notice(%Citizen{} = citizen, now \\ clock().utc_now()) do
    deletion_at = DateTime.shift(citizen.last_sign_in_at || citizen.inserted_at, month: 6)

    cond do
      DateTime.compare(now, deletion_at) != :lt ->
        {:deadline, deletion_at}

      DateTime.compare(now, DateTime.add(deletion_at, -7, :day)) != :lt ->
        {:warning, 7, deletion_at}

      DateTime.compare(now, DateTime.add(deletion_at, -30, :day)) != :lt ->
        {:warning, 30, deletion_at}

      true ->
        nil
    end
  end

  @doc "Runs one traffic-independent inactivity lifecycle pass at an injected UTC instant."
  def run_inactivity_retention(now \\ clock().utc_now(), resolutions \\ %{}) do
    actor = %{principal: :system}

    Citizen
    |> Ash.Query.for_read(:retention_candidates, %{}, actor: actor)
    |> Ash.read!(actor: actor, authorize?: true, domain: __MODULE__)
    |> Enum.map(&process_inactive_citizen(&1, now, resolutions, actor))
  end

  defp process_inactive_citizen(citizen, now, resolutions, actor) do
    cycle_at = citizen.last_sign_in_at || citizen.inserted_at
    deletion_at = DateTime.shift(cycle_at, month: 6)

    cond do
      DateTime.compare(now, deletion_at) != :lt ->
        case delete_citizen(
               citizen,
               Map.get(resolutions, citizen.id, %{}) |> Map.put_new(:reason, :inactivity)
             ) do
          {:ok, _} = ok -> ok
          {:error, :owned_collection_requires_resolution} -> {:blocked, citizen.id}
          {:error, reason} -> {:error, reason}
        end

      DateTime.compare(now, DateTime.add(deletion_at, -7, :day)) != :lt ->
        warn(citizen, cycle_at, deletion_at, 7, now, actor)

      DateTime.compare(now, DateTime.add(deletion_at, -30, :day)) != :lt ->
        warn(citizen, cycle_at, deletion_at, 30, now, actor)

      true ->
        :ok
    end
  end

  defp warn(citizen, cycle_at, deletion_at, days, now, actor) do
    warning =
      BrusselsWtf.Follow.RetentionWarning
      |> Ash.Changeset.for_create(:record, %{
        citizen_id: citizen.id,
        inactivity_cycle_at: cycle_at,
        days_before_deletion: days,
        warned_at: now,
        delivery_status: :failed,
        delivery_attempted_at: now
      })
      |> Ash.create!(actor: actor, authorize?: true, domain: BrusselsWtf.Follow)

    if warning.delivery_status == :failed do
      {subject, body} = inactivity_warning_copy(citizen.preferred_locale, days, deletion_at)
      mail = Application.fetch_env!(:brussels_wtf, :citizen_mailer)

      status =
        case mail.deliver_inactivity_warning(
               citizen.email,
               citizen.preferred_locale,
               subject,
               body,
               deletion_at
             ) do
          :ok -> :delivered
          {:error, _} -> :failed
        end

      warning
      |> Ash.Changeset.for_update(:record_delivery, %{
        delivery_status: status,
        delivery_attempted_at: now
      })
      |> Ash.update!(actor: actor, authorize?: true, domain: BrusselsWtf.Follow)

      if status == :delivered, do: {:warned, days}, else: {:warning_delivery_failed, days}
    else
      {:already_warned, days}
    end
  end

  defp inactivity_warning_copy(locale, days, deletion_at) do
    date = Calendar.strftime(deletion_at, "%Y-%m-%d")
    path = "/citizen/account/retention"

    case locale do
      "fr" ->
        {"Votre compte sera supprimé dans #{days} jours",
         "Connectez-vous avant le #{date} pour conserver votre compte. Gérez vos collections sur #{path}."}

      "nl" ->
        {"Uw account wordt over #{days} dagen verwijderd",
         "Meld u aan vóór #{date} om uw account te behouden. Beheer uw collecties via #{path}."}

      _ ->
        {"Your account will be deleted in #{days} days",
         "Sign in before #{date} to keep your account. Resolve your collections at #{path}."}
    end
  end

  @doc "Deletes an account and all authentication state in one transaction."
  def delete_account(%Citizen{} = citizen) do
    security_transaction(fn -> delete_account_steps(citizen) end)
  end

  defp delete_account_steps(citizen) do
    outstanding_jtis = outstanding_magic_link_jtis_checked(citizen.email)
    :ok = maybe_fail(:sessions)
    :ok = revoke_sessions_checked(citizen.id)
    :ok = maybe_fail(:outstanding_links)
    :ok = revoke_outstanding_magic_links_checked(citizen.email)
    :ok = maybe_fail(:authentication_tokens)
    :ok = revoke_authentication_tokens_checked(citizen)
    :ok = purge_authentication_tokens_checked(citizen, outstanding_jtis)
    :ok = maybe_fail(:citizen)

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
    actor = %{principal: :system}

    BrusselsWtf.Accounts.Token
    |> Ash.Query.for_read(
      :for_account_deletion,
      %{
        citizen_id: citizen.id,
        outstanding_jtis: outstanding_jtis
      },
      actor: actor
    )
    |> Ash.read(actor: actor, authorize?: true, domain: __MODULE__)
    |> checked_value()
    |> Enum.each(&destroy_record_checked(&1, :revoke_stored, actor, __MODULE__))

    :ok
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
