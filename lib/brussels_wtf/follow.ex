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

  @doc "Create a durable follow through the citizen authorization boundary."
  def follow(citizen, type, identifier) do
    with {:ok, target} <- Target.new(type, identifier),
         true <- TargetEligibility.eligible?(target) do
      CitizenFollow
      |> Ash.Changeset.for_create(:follow, %{
        citizen_id: citizen.id,
        target_type: target.type,
        target_identifier: target.identifier
      })
      |> Ash.create(actor: citizen_actor(citizen), authorize?: true, domain: __MODULE__)
    else
      _ -> {:error, :ineligible}
    end
  end

  @doc "Synchronize every persisted follow from the authoritative public projections."
  def synchronize_registered_feeds do
    actor = %{principal: :system}

    CitizenFollow
    |> Ash.Query.for_read(:all_for_sync)
    |> Ash.read!(actor: actor, authorize?: true, domain: __MODULE__)
    |> Enum.reduce_while({:ok, 0}, fn follow, {:ok, count} ->
      case synchronize_follow(follow, actor) do
        {:ok, delivered} -> {:cont, {:ok, count + delivered}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp synchronize_follow(follow, actor) do
    target = %Target{type: follow.target_type, identifier: follow.target_identifier}

    BrusselsWtf.Follow.PublicUpdates.list(
      [
        %{
          "type" => Atom.to_string(target.type),
          "id" => target.identifier,
          "importedAt" => DateTime.to_iso8601(follow.inserted_at)
        }
      ],
      "en"
    )
    |> Enum.reduce_while({:ok, 0}, fn update, {:ok, count} ->
      attrs = %{
        citizen_id: follow.citizen_id,
        target_type: follow.target_type,
        target_identifier: follow.target_identifier,
        event_identity: update.publicEventId,
        event_kind: update.eventType,
        public_url: update.url,
        occurred_at: parse_occurred_at!(update.occurredAt)
      }

      case deliver_exactly_once(attrs, actor) do
        {:ok, :created} -> {:cont, {:ok, count + 1}}
        {:ok, :existing} -> {:cont, {:ok, count}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp deliver_exactly_once(attrs, actor) do
    existing =
      FeedUpdate
      |> Ash.Query.for_read(:for_delivery_identity, %{
        citizen_id: attrs.citizen_id,
        event_identity: attrs.event_identity
      })
      |> Ash.read_one!(actor: actor, authorize?: true, domain: __MODULE__)

    case existing do
      nil ->
        case FeedUpdate
             |> Ash.Changeset.for_create(:deliver_once, attrs)
             |> Ash.create(actor: actor, authorize?: true, domain: __MODULE__) do
          {:ok, _} -> {:ok, :created}
          {:error, _} -> deliver_exactly_once(attrs, actor)
        end

      record ->
        if delivery_bytes(record) == delivery_bytes(attrs),
          do: {:ok, :existing},
          else: {:error, :public_event_identity_reused}
    end
  end

  defp delivery_bytes(value) do
    [
      :citizen_id,
      :target_type,
      :target_identifier,
      :event_identity,
      :event_kind,
      :public_url,
      :occurred_at
    ]
    |> Enum.map(&Map.fetch!(value, &1))
    |> :erlang.term_to_binary()
  end

  defp parse_occurred_at!(value) do
    {:ok, timestamp, 0} = DateTime.from_iso8601(value)
    timestamp
  end

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

  @doc "Purges deliveries, including read state, at their exact 12-calendar-month boundary."
  def purge_notifications(now \\ Application.fetch_env!(:brussels_wtf, :clock).utc_now()) do
    cutoff = DateTime.shift(now, month: -12)
    actor = %{principal: :system}

    updates =
      FeedUpdate
      |> Ash.Query.filter(inserted_at <= ^cutoff)
      |> Ash.read!(actor: actor, authorize?: true, domain: __MODULE__)

    Enum.each(
      updates,
      &Ash.destroy!(&1, action: :purge, actor: actor, authorize?: true, domain: __MODULE__)
    )

    {:ok, length(updates)}
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
