defmodule BrusselsWtf.Follow do
  @moduledoc "Anonymous follow collections with separate view and management capabilities."

  use Ash.Domain, otp_app: :brussels_wtf

  require Ash.Query
  require Logger
  import Ecto.Query, only: [from: 2]

  alias BrusselsWtf.Follow.{
    CitizenFollow,
    Collection,
    Member,
    Target,
    TargetEligibility,
    FeedUpdate,
    CollectionGrant,
    CollectionTransferOffer,
    DeletionAudit,
    RetentionWarning,
    InactivityOwnershipResolution
  }

  resources do
    resource Collection
    resource Member
    resource CitizenFollow
    resource FeedUpdate
    resource CollectionGrant
    resource CollectionTransferOffer
    resource DeletionAudit
    resource RetentionWarning
    resource InactivityOwnershipResolution
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
    locale = citizen_locale(follow.citizen_id)

    updates =
      BrusselsWtf.Follow.PublicUpdates.list(
        [
          %{
            "type" => Atom.to_string(target.type),
            "id" => target.identifier,
            "importedAt" => DateTime.to_iso8601(follow.inserted_at)
          }
        ],
        locale
      )

    with :ok <- remove_stale_deliveries(follow, updates, actor) do
      Enum.reduce_while(updates, {:ok, 0}, fn update, {:ok, count} ->
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
  end

  defp citizen_locale(citizen_id) do
    case Ash.get(BrusselsWtf.Accounts.Citizen, citizen_id,
           action: :system_by_id,
           args: %{id: citizen_id},
           actor: %{principal: :system},
           authorize?: true,
           domain: BrusselsWtf.Accounts
         ) do
      {:ok, citizen} -> citizen.preferred_locale
      _ -> "en"
    end
  end

  defp remove_stale_deliveries(follow, updates, actor) do
    expected =
      Map.new(updates, fn update ->
        {update.publicEventId,
         {update.eventType, update.url, parse_occurred_at!(update.occurredAt)}}
      end)

    FeedUpdate
    |> Ash.Query.for_read(:for_follow, %{
      citizen_id: follow.citizen_id,
      target_type: follow.target_type,
      target_identifier: follow.target_identifier
    })
    |> Ash.read!(actor: actor, authorize?: true, domain: __MODULE__)
    |> Enum.filter(fn delivery ->
      Map.get(expected, delivery.event_identity) !=
        {delivery.event_kind, delivery.public_url, delivery.occurred_at}
    end)
    |> Enum.each(
      &Ash.destroy!(&1, action: :remove_stale, actor: actor, authorize?: true, domain: __MODULE__)
    )

    :ok
  end

  defp deliver_exactly_once(attrs, actor) do
    existing =
      FeedUpdate
      |> Ash.Query.for_read(:for_delivery_identity, %{
        citizen_id: attrs.citizen_id,
        target_type: attrs.target_type,
        target_identifier: attrs.target_identifier,
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
    system = %{principal: :system}

    CitizenFollow
    |> Ash.Query.for_read(:all_for_sync)
    |> Ash.Query.filter(citizen_id == ^citizen.id)
    |> Ash.read!(actor: system, authorize?: true, domain: __MODULE__)
    |> Enum.each(fn follow ->
      {:ok, _} = synchronize_follow(follow, system)
    end)

    FeedUpdate
    |> Ash.Query.for_read(:mine, %{}, actor: actor)
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.read(actor: actor, authorize?: true, domain: __MODULE__)
  end

  def mark_read(citizen, id) do
    with {:ok, update} <-
           Ash.get(FeedUpdate, id,
             action: :mine_by_id,
             args: %{id: id},
             actor: citizen_actor(citizen),
             authorize?: true,
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

    owner_result = owner_collection(citizen, collection_id)

    result =
      case owner_result do
        {:ok, collection} ->
          {:ok, collection}

        _ ->
          Collection
          |> Ash.Query.for_read(:view_granted, %{id: collection_id}, actor: actor)
          |> Ash.read_one(actor: actor, authorize?: true, domain: __MODULE__)
          |> not_found()
      end

    with {:ok, collection} <- result,
         true <- collection.visibility == :private do
      Ash.load(collection, :members,
        actor: %{collection_id: collection.id},
        authorize?: true,
        domain: __MODULE__
      )
    else
      _ -> {:error, :not_found}
    end
  end

  defp citizen_actor(c), do: %{id: c.id, principal: :citizen}

  def owner_collection(citizen, collection_id) do
    actor = citizen_actor(citizen)

    with {:ok, collection} <-
           Collection
           |> Ash.Query.for_read(:manage_owned, %{id: collection_id}, actor: actor)
           |> Ash.read_one(actor: actor, authorize?: true, domain: __MODULE__)
           |> not_found() do
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
      |> Ash.Changeset.for_create(:grant_view, %{
        collection_id: collection.id,
        citizen_id: recipient_id,
        owner_citizen_id: citizen.id
      })
      |> Ash.create(actor: citizen_actor(citizen), authorize?: true, domain: __MODULE__)
    else
      _ -> {:error, :not_found}
    end
  end

  def revoke_private_view(citizen, collection_id, grant_id) do
    with {:ok, collection} <- owner_collection(citizen, collection_id),
         {:ok, grant} <-
           CollectionGrant
           |> Ash.Query.for_read(
             :get_for_owner,
             %{
               id: grant_id,
               collection_id: collection.id
             },
             actor: citizen_actor(citizen)
           )
           |> Ash.read_one(
             actor: citizen_actor(citizen),
             authorize?: true,
             domain: __MODULE__
           )
           |> not_found(),
         true <- grant.collection_id == collection.id do
      grant
      |> Ash.Changeset.for_destroy(:revoke_view, %{collection_id: collection.id})
      |> Ash.destroy(
        actor: citizen_actor(citizen),
        authorize?: true,
        domain: __MODULE__
      )
    else
      _ -> {:error, :not_found}
    end
  end

  def owner_collections(citizen) do
    actor = citizen_actor(citizen)

    Collection
    |> Ash.Query.for_read(:owned, %{}, actor: actor)
    |> Ash.read(actor: actor, authorize?: true, domain: __MODULE__)
  end

  def list_private_grants(citizen, collection_id) do
    actor = citizen_actor(citizen)

    CollectionGrant
    |> Ash.Query.for_read(:list_for_owned_collection, %{collection_id: collection_id},
      actor: actor
    )
    |> Ash.read(actor: actor, authorize?: true, domain: __MODULE__)
  end

  @doc "Creates a recipient-bound transfer offer and returns its raw token exactly once."
  def offer_collection_transfer(citizen, collection_id, recipient_id) do
    with false <- recipient_id == citizen.id,
         {:ok, collection} <- owner_collection(citizen, collection_id),
         true <- collection.visibility in [:public, :unlisted] do
      raw_token = token()
      now = Application.fetch_env!(:brussels_wtf, :clock).utc_now()
      actor = citizen_actor(citizen)

      BrusselsWtf.Repo.transaction(fn ->
        CollectionTransferOffer
        |> Ash.Query.for_read(:for_owner, %{collection_id: collection.id}, actor: actor)
        |> Ash.read!(actor: actor, authorize?: true, domain: __MODULE__)
        |> Enum.filter(&(is_nil(&1.accepted_at) and is_nil(&1.cancelled_at)))
        |> Enum.each(fn offer ->
          offer
          |> Ash.Changeset.for_update(:cancel, %{cancelled_at: now})
          |> Ash.update!(actor: actor, authorize?: true, domain: __MODULE__)
        end)

        offer =
          CollectionTransferOffer
          |> Ash.Changeset.for_create(:offer, %{
            collection_id: collection.id,
            from_citizen_id: citizen.id,
            to_citizen_id: recipient_id,
            token_hash: hash(raw_token),
            expires_at: DateTime.add(now, 7, :day)
          })
          |> Ash.create!(actor: actor, authorize?: true, domain: __MODULE__)

        {offer, raw_token}
      end)
      |> case do
        {:ok, {offer, token}} -> {:ok, offer, token}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :invalid_recipient}
      _ -> {:error, :not_found}
    end
  end

  def list_collection_transfer_offers(citizen, collection_id) do
    actor = citizen_actor(citizen)

    CollectionTransferOffer
    |> Ash.Query.for_read(:for_owner, %{collection_id: collection_id}, actor: actor)
    |> Ash.read(actor: actor, authorize?: true, domain: __MODULE__)
  end

  def collection_transfer_offer(citizen, raw_token) do
    actor = citizen_actor(citizen)

    CollectionTransferOffer
    |> Ash.Query.for_read(:by_recipient_token, %{token_hash: hash(raw_token)}, actor: actor)
    |> Ash.read_one(actor: actor, authorize?: true, domain: __MODULE__)
    |> not_found()
  end

  def accept_collection_transfer(citizen, raw_token) do
    now = Application.fetch_env!(:brussels_wtf, :clock).utc_now()
    actor = citizen_actor(citizen)

    BrusselsWtf.Repo.transaction(fn ->
      with {:ok, offer} <- collection_transfer_offer(citizen, raw_token),
           :lt <- DateTime.compare(now, offer.expires_at),
           {:ok, collection} <- lock_transfer_collection(offer),
           true <- collection.owner_citizen_id == offer.from_citizen_id,
           {:ok, transferred} <-
             collection
             |> Ash.Changeset.for_update(:transfer_owned, %{
               owner_citizen_id: citizen.id,
               expected_owner_citizen_id: offer.from_citizen_id
             })
             |> Ash.update(actor: %{principal: :system}, authorize?: true, domain: __MODULE__),
           :ok <- clear_collection_inactivity_resolutions(collection.id),
           {:ok, _} <-
             offer
             |> Ash.Changeset.for_update(:accept, %{accepted_at: now})
             |> Ash.update(actor: actor, authorize?: true, domain: __MODULE__) do
        transferred
      else
        :eq -> BrusselsWtf.Repo.rollback(:expired)
        :gt -> BrusselsWtf.Repo.rollback(:expired)
        _ -> BrusselsWtf.Repo.rollback(:not_found)
      end
    end)
  end

  def decline_collection_transfer(citizen, raw_token) do
    with {:ok, offer} <- collection_transfer_offer(citizen, raw_token) do
      offer
      |> Ash.Changeset.for_update(:decline, %{
        cancelled_at: Application.fetch_env!(:brussels_wtf, :clock).utc_now()
      })
      |> Ash.update(actor: citizen_actor(citizen), authorize?: true, domain: __MODULE__)
    end
  end

  def cancel_collection_transfer(citizen, offer_id) do
    actor = citizen_actor(citizen)

    with {:ok, offer} <-
           Ash.get(CollectionTransferOffer, offer_id,
             action: :get_for_owner,
             args: %{id: offer_id},
             actor: actor,
             authorize?: true,
             domain: __MODULE__
           ) do
      offer
      |> Ash.Changeset.for_update(:cancel, %{
        cancelled_at: Application.fetch_env!(:brussels_wtf, :clock).utc_now()
      })
      |> Ash.update(actor: actor, authorize?: true, domain: __MODULE__)
    else
      _ -> {:error, :not_found}
    end
  end

  def delete_owned_collection(citizen, collection_id) do
    with {:ok, collection} <- owner_collection(citizen, collection_id) do
      Ash.destroy(collection,
        action: :delete_owned,
        actor: citizen_actor(citizen),
        authorize?: true,
        domain: __MODULE__
      )
    end
  end

  defp lock_transfer_collection(offer) do
    case BrusselsWtf.Repo.query(
           "SELECT id FROM follow_collections WHERE id=$1 FOR UPDATE",
           [Ecto.UUID.dump!(offer.collection_id)]
         ) do
      {:ok, %{num_rows: 1}} ->
        actor = %{principal: :system}

        Collection
        |> Ash.Query.for_read(:get_for_transfer, %{id: offer.collection_id}, actor: actor)
        |> Ash.read_one(actor: actor, authorize?: true, domain: __MODULE__)

      _ ->
        {:error, :not_found}
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

  def clear_inactivity_resolutions(citizen_id) do
    {_, _} =
      BrusselsWtf.Repo.delete_all(
        from r in "citizen_inactivity_ownership_resolutions",
          where: r.citizen_id == type(^citizen_id, Ecto.UUID)
      )

    {_, _} =
      BrusselsWtf.Repo.delete_all(
        from r in "citizen_retention_warnings",
          where: r.citizen_id == type(^citizen_id, Ecto.UUID)
      )

    :ok
  end

  defp clear_collection_inactivity_resolutions(collection_id) do
    {_, _} =
      BrusselsWtf.Repo.delete_all(
        from r in "citizen_inactivity_ownership_resolutions",
          where: r.collection_id == type(^collection_id, Ecto.UUID)
      )

    :ok
  end

  def inactivity_resolutions(citizen) do
    cycle = citizen.last_sign_in_at || citizen.inserted_at
    actor = citizen_actor(citizen)

    InactivityOwnershipResolution
    |> Ash.Query.filter(citizen_id == ^citizen.id and inactivity_cycle_at == ^cycle)
    |> Ash.read(actor: actor, authorize?: true, domain: __MODULE__)
  end

  def select_inactivity_resolution(citizen, collection_id, choice)
      when choice in [:delete, :transfer] do
    with {:ok, collection} <- owner_collection(citizen, collection_id),
         true <- collection.visibility != :private do
      InactivityOwnershipResolution
      |> Ash.Changeset.for_create(:select, %{
        citizen_id: citizen.id,
        collection_id: collection.id,
        inactivity_cycle_at: citizen.last_sign_in_at || citizen.inserted_at,
        choice: choice
      })
      |> Ash.create(actor: citizen_actor(citizen), authorize?: true, domain: __MODULE__)
    else
      _ -> {:error, :not_found}
    end
  end

  def revoke_inactivity_resolution(citizen, collection_id) do
    with {:ok, choices} <- inactivity_resolutions(citizen),
         %{} = choice <- Enum.find(choices, &(&1.collection_id == collection_id)) do
      Ash.destroy(choice,
        action: :revoke,
        actor: citizen_actor(citizen),
        authorize?: true,
        domain: __MODULE__
      )
    else
      _ -> {:error, :not_found}
    end
  end

  def system_inactivity_resolutions(citizen) do
    cycle = citizen.last_sign_in_at || citizen.inserted_at
    actor = %{principal: :system}

    InactivityOwnershipResolution
    |> Ash.Query.for_read(:for_cycle, %{citizen_id: citizen.id, inactivity_cycle_at: cycle},
      actor: actor
    )
    |> Ash.read!(actor: actor, authorize?: true, domain: __MODULE__)
    |> Map.new(&{&1.collection_id, &1.choice})
  end
end
