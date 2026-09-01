defmodule BrusselsWtf.Follow do
  @moduledoc "Anonymous follow collections with separate view and management capabilities."

  use Ash.Domain, otp_app: :brussels_wtf

  require Ash.Query
  require Logger
  alias BrusselsWtf.Follow.{CitizenFollow, Collection, Member, Target, TargetEligibility}

  resources do
    resource Collection
    resource Member
    resource CitizenFollow
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
