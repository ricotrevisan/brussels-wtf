defmodule BrusselsWtf.Follow do
  @moduledoc "Anonymous follow collections with separate view and management capabilities."

  use Ash.Domain, otp_app: :brussels_wtf

  require Ash.Query
  require Logger

  alias BrusselsWtf.Follow.{
    CitizenFollow,
    Collection,
    Member,
    Target,
    TargetEligibility,
    FeedUpdate,
    CollectionGrant,
    DeletionAudit,
    RetentionWarning
  }

  resources do
    resource Collection
    resource Member
    resource CitizenFollow
    resource FeedUpdate
    resource CollectionGrant
    resource DeletionAudit
    resource RetentionWarning
  end

  def import_citizen_follows(citizen, targets) when is_list(targets) do
    actor = %{id: citizen.id, principal: :citizen}

    Enum.reduce_while(targets, {:ok, []}, fn {type, identifier}, {:ok, records} ->
      with {:ok, target} <- Target.new(type, identifier),
           true <- TargetEligibility.eligible?(target),
           {:ok, follow} <-
             CitizenFollow
             |> Ash.Changeset.for_create(:import, %{
               citizen_id: citizen.id,
               target_type: type,
               target_identifier: identifier
             })
             |> Ash.create(actor: actor, authorize?: true, domain: __MODULE__) do
        {:cont, {:ok, [follow | records]}}
      else
        _ -> {:halt, {:error, :ineligible}}
      end
    end)
  end

  @qualifying %{
    dossier: [:linked_agenda_item, :decision, :correction, :merge, :split],
    person: [:verified_public_mandate, :verified_management_role, :relevant_council_item],
    legal_entity: [:verified_management_role, :contract_award, :relevant_council_item],
    commune: [:published_meeting_page, :revision_with_new_decisions]
  }

  @doc "Deliver one immutable update to every follower. Non-public and excluded events fail closed."
  def publish_update(
        %{
          target_type: type,
          target_identifier: identifier,
          kind: kind,
          identity: identity,
          public_url: url,
          occurred_at: at
        } = event
      ) do
    if event[:public?] == true and kind in Map.get(@qualifying, type, []) and
         is_binary(identity) and is_binary(url) and String.starts_with?(url, "/") do
      actor = %{principal: :system}

      CitizenFollow
      |> Ash.Query.filter(target_type == ^type and target_identifier == ^identifier)
      |> Ash.read!(actor: actor, authorize?: false, domain: __MODULE__)
      |> Enum.reduce_while({:ok, []}, fn follow, {:ok, delivered} ->
        result =
          FeedUpdate
          |> Ash.Changeset.for_create(:deliver, %{
            citizen_id: follow.citizen_id,
            target_type: type,
            target_identifier: identifier,
            event_identity: identity,
            event_kind: kind,
            public_url: url,
            occurred_at: at
          })
          |> Ash.create(actor: actor, authorize?: true, domain: __MODULE__)

        case result do
          {:ok, update} -> {:cont, {:ok, [update | delivered]}}
          error -> {:halt, error}
        end
      end)
    else
      {:ok, []}
    end
  end

  def publish_update(_), do: {:ok, []}

  def registered_feed(citizen) do
    actor = citizen_actor(citizen)

    FeedUpdate
    |> Ash.Query.for_read(:mine, %{}, actor: actor)
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.read(actor: actor, authorize?: true, domain: __MODULE__)
  end

  def mark_read(citizen, id) do
    with {:ok, update} <-
           Ash.get(FeedUpdate, id,
             actor: citizen_actor(citizen),
             authorize?: false,
             domain: __MODULE__
           ) do
      update
      |> Ash.Changeset.for_update(:mark_read)
      |> Ash.update(actor: citizen_actor(citizen), authorize?: true, domain: __MODULE__)
    end
  end

  def purge_notifications(now \\ Application.fetch_env!(:brussels_wtf, :clock).utc_now()) do
    cutoff = DateTime.add(now, -365, :day)

    FeedUpdate
    |> Ash.Query.filter(occurred_at <= ^cutoff)
    |> Ash.read!(actor: %{principal: :system}, authorize?: true, domain: __MODULE__)
    |> Enum.each(
      &Ash.destroy!(&1,
        action: :purge,
        actor: %{principal: :system},
        authorize?: true,
        domain: __MODULE__
      )
    )

    :ok
  end

  def private_collection(collection_id, citizen) do
    actor = citizen_actor(citizen)

    with {:ok, collection} <-
           Ash.get(Collection, collection_id, actor: actor, authorize?: false, domain: __MODULE__),
         true <- collection.visibility == :private,
         true <- collection.owner_citizen_id == citizen.id or granted?(collection.id, citizen.id) do
      Ash.load(collection, :members,
        actor: %{collection_id: collection.id},
        authorize?: true,
        domain: __MODULE__
      )
    else
      _ -> {:error, :not_found}
    end
  end

  defp granted?(collection_id, citizen_id) do
    result =
      CollectionGrant
      |> Ash.Query.filter(collection_id == ^collection_id and citizen_id == ^citizen_id)
      |> Ash.read_one!(actor: %{principal: :system}, authorize?: true, domain: __MODULE__)

    not is_nil(result)
  end

  defp citizen_actor(c), do: %{id: c.id, principal: :citizen}

  def owner_collection(citizen, collection_id) do
    actor = citizen_actor(citizen)

    with {:ok, collection} <-
           Ash.get(Collection, collection_id, actor: actor, authorize?: false, domain: __MODULE__),
         true <- collection.owner_citizen_id == citizen.id do
      Ash.load(collection, :members,
        actor: %{collection_id: collection.id},
        authorize?: true,
        domain: __MODULE__
      )
    else
      _ -> {:error, :not_found}
    end
  end

  def owner_set_visibility(citizen, collection_id, visibility)
      when visibility in [:public, :unlisted, :private] do
    with {:ok, collection} <- owner_collection(citizen, collection_id) do
      update(
        collection,
        :set_visibility,
        %{
          visibility: visibility,
          last_used_at: Application.fetch_env!(:brussels_wtf, :clock).utc_now()
        },
        %{collection_id: collection.id}
      )
    end
  end

  def owner_set_visibility(_, _, _), do: {:error, :invalid_visibility}

  def owner_add_member(citizen, collection_id, type, identifier) do
    with {:ok, target} <- Target.new(type, identifier),
         true <- TargetEligibility.eligible?(target),
         {:ok, collection} <- owner_collection(citizen, collection_id),
         {:ok, _} <- add_member(collection.id, target, %{collection_id: collection.id}) do
      regenerate(
        collection,
        %{collection_id: collection.id},
        Application.fetch_env!(:brussels_wtf, :clock).utc_now()
      )
    else
      _ -> {:error, :not_found}
    end
  end

  def grant_private_view(citizen, collection_id, recipient_id) do
    with {:ok, collection} <- owner_collection(citizen, collection_id),
         true <- collection.visibility == :private,
         false <- recipient_id == citizen.id do
      CollectionGrant
      |> Ash.Changeset.for_create(:grant, %{
        collection_id: collection.id,
        citizen_id: recipient_id
      })
      |> Ash.create(actor: %{principal: :system}, authorize?: true, domain: __MODULE__)
    else
      _ -> {:error, :not_found}
    end
  end

  def revoke_private_view(citizen, collection_id, grant_id) do
    with {:ok, collection} <- owner_collection(citizen, collection_id),
         {:ok, grant} <-
           Ash.get(CollectionGrant, grant_id,
             actor: %{principal: :system},
             authorize?: true,
             domain: __MODULE__
           ),
         true <- grant.collection_id == collection.id do
      Ash.destroy(grant,
        action: :revoke,
        actor: %{principal: :system},
        authorize?: true,
        domain: __MODULE__
      )
    else
      _ -> {:error, :not_found}
    end
  end

  def claim_collection(secret, citizen) do
    with {:ok, collection} <- capability_collection(secret),
         true <- is_nil(collection.owner_citizen_id) do
      collection
      |> Ash.Changeset.for_update(:claim, %{owner_citizen_id: citizen.id})
      |> Ash.update(
        actor: %{id: citizen.id, principal: :citizen},
        authorize?: true,
        domain: __MODULE__
      )
    else
      _ -> {:error, :not_found}
    end
  end

  def create_collection(now \\ Application.fetch_env!(:brussels_wtf, :clock).utc_now()) do
    view = token()
    secret = token()

    result =
      Collection
      |> Ash.Changeset.for_create(:create, %{
        view_token: view,
        management_secret_hash: hash(secret),
        title: "Brussels follow collection",
        last_used_at: now
      })
      |> Ash.create(authorize?: true, domain: __MODULE__)

    case result do
      {:ok, collection} -> {:ok, collection, secret}
      error -> error
    end
  end

  def view(view_token) do
    result =
      Collection
      |> Ash.Query.for_read(:by_view_token, %{view_token: view_token})
      |> Ash.read_one(authorize?: true, domain: __MODULE__)
      |> not_found()

    with {:ok, collection} <- result do
      Ash.load(collection, :members,
        actor: actor(collection.id),
        authorize?: true,
        domain: __MODULE__
      )
    end
  end

  def exchange(secret, now \\ Application.fetch_env!(:brussels_wtf, :clock).utc_now()) do
    with {:ok, collection} <- capability_collection(secret) do
      update(collection, :touch, %{last_used_at: now}, actor(collection.id))
    end
  end

  def manage_session(
        collection_id,
        now \\ Application.fetch_env!(:brussels_wtf, :clock).utc_now()
      ) do
    actor = actor(collection_id)

    with {:ok, collection} <- managed_collection(collection_id, actor),
         {:ok, touched} <- update(collection, :touch, %{last_used_at: now}, actor) do
      Ash.load(touched, :members, actor: actor, authorize?: true, domain: __MODULE__)
    end
  end

  def set_visibility_session(
        collection_id,
        visibility,
        now \\ Application.fetch_env!(:brussels_wtf, :clock).utc_now()
      )

  def set_visibility_session(collection_id, visibility, now)
      when visibility in [:public, :unlisted, :private] do
    actor = actor(collection_id)

    with {:ok, collection} <- managed_collection(collection_id, actor) do
      update(collection, :set_visibility, %{visibility: visibility, last_used_at: now}, actor)
    end
  end

  def set_visibility_session(_, _, _), do: {:error, :invalid_visibility}

  def add_member_session(
        collection_id,
        type,
        identifier,
        now \\ Application.fetch_env!(:brussels_wtf, :clock).utc_now()
      ) do
    actor = actor(collection_id)

    with {:ok, target} <- Target.new(type, identifier),
         true <- TargetEligibility.eligible?(target),
         {:ok, collection} <- managed_collection(collection_id, actor),
         {:ok, _member} <- add_member(collection.id, target, actor),
         {:ok, updated} <- regenerate(collection, actor, now) do
      {:ok, updated}
    else
      false -> {:error, :ineligible}
      error -> error
    end
  end

  def remove_member_session(
        collection_id,
        type,
        identifier,
        now \\ Application.fetch_env!(:brussels_wtf, :clock).utc_now()
      ) do
    actor = actor(collection_id)

    with {:ok, target} <- Target.new(type, identifier),
         {:ok, collection} <- managed_collection(collection_id, actor),
         :ok <- remove_members(collection.id, target, actor),
         {:ok, updated} <- regenerate(collection, actor, now) do
      {:ok, updated}
    end
  end

  def expire_unused(now \\ Application.fetch_env!(:brussels_wtf, :clock).utc_now()) do
    Collection
    |> Ash.read!(authorize?: false, domain: __MODULE__)
    |> Enum.filter(&(DateTime.compare(DateTime.shift(&1.last_used_at, month: 12), now) != :gt))
    |> Enum.count(fn collection ->
      Ash.destroy(collection,
        action: :expire,
        actor: %{role: :maintenance},
        authorize?: true,
        domain: __MODULE__
      ) == :ok
    end)
  end

  defp capability_collection(secret) when is_binary(secret) do
    Logger.warning("follow_collection_capability_checked")

    Collection
    |> Ash.Query.for_read(:exchange_capability, %{management_secret_hash: hash(secret)})
    |> Ash.read_one(authorize?: true, domain: __MODULE__)
    |> not_found()
  end

  defp capability_collection(_), do: {:error, :not_found}

  defp managed_collection(id, actor) do
    Collection
    |> Ash.Query.for_read(:manage, %{id: id})
    |> Ash.read_one(actor: actor, authorize?: true, domain: __MODULE__)
    |> not_found()
  end

  defp add_member(collection_id, target, actor) do
    Member
    |> Ash.Changeset.for_create(:add, %{
      collection_id: collection_id,
      target_type: target.type,
      target_identifier: target.identifier
    })
    |> Ash.create(actor: actor, authorize?: true, domain: __MODULE__)
  end

  defp remove_members(collection_id, target, actor) do
    Member
    |> Ash.Query.filter(
      collection_id == ^collection_id and target_type == ^target.type and
        target_identifier == ^target.identifier
    )
    |> Ash.read!(actor: actor, authorize?: true, domain: __MODULE__)
    |> Enum.each(&Ash.destroy!(&1, actor: actor, authorize?: true, domain: __MODULE__))

    :ok
  end

  defp regenerate(collection, actor, now) do
    members =
      Member
      |> Ash.Query.filter(collection_id == ^collection.id)
      |> Ash.read!(actor: actor, authorize?: true, domain: __MODULE__)

    count = length(members)

    title =
      if count == 0,
        do: "Brussels follow collection",
        else: "Following #{count} public #{if count == 1, do: "resource", else: "resources"}"

    update(collection, :set_title, %{title: title, last_used_at: now}, actor)
  end

  defp update(record, action, attrs, actor) do
    record
    |> Ash.Changeset.for_update(action, attrs)
    |> Ash.update(actor: actor, authorize?: true, domain: __MODULE__)
  end

  defp not_found({:ok, nil}), do: {:error, :not_found}
  defp not_found({:error, %Ash.Error.Forbidden{}}), do: {:error, :not_found}
  defp not_found(result), do: result
  defp actor(id), do: %{collection_id: id}
  defp token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  defp hash(secret), do: :crypto.hash(:sha256, secret)
end
