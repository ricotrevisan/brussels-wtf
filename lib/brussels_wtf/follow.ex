defmodule BrusselsWtf.Follow do
  @moduledoc "Anonymous follow collections with separate view and management capabilities."
  import Ecto.Query
  alias BrusselsWtf.{Repo, Follow.Collection, Follow.Member}
  @year 365 * 24 * 60 * 60

  def create_collection do
    view = token()
    secret = token()
    now = DateTime.utc_now()

    changes = %{
      view_token: view,
      management_secret_hash: hash(secret),
      visibility: :unlisted,
      title: "Brussels follow collection",
      last_used_at: now
    }

    with {:ok, collection} <- %Collection{} |> Ecto.Changeset.change(changes) |> Repo.insert() do
      {:ok, collection, secret}
    end
  end

  def view(view_token) do
    case Repo.one(from c in Collection, where: c.view_token == ^view_token, preload: :members) do
      %{visibility: :private} -> {:error, :not_found}
      nil -> {:error, :not_found}
      collection -> {:ok, collection}
    end
  end

  def manage(secret) do
    case Repo.one(
           from c in Collection,
             where: c.management_secret_hash == ^hash(secret),
             preload: :members
         ) do
      nil -> {:error, :not_found}
      collection -> {:ok, collection}
    end
  end

  def set_visibility(secret, visibility) when visibility in [:public, :unlisted, :private] do
    with {:ok, c} <- manage(secret),
         do: c |> Ecto.Changeset.change(visibility: visibility) |> Repo.update()
  end

  def set_visibility(_, _), do: {:error, :invalid_visibility}

  def add_member(secret, type, identifier)
      when type in [:dossier, :person, :legal_entity, :commune] do
    with {:ok, c} <- manage(secret), true <- eligible?(type, identifier) do
      %Member{}
      |> Ecto.Changeset.change(
        collection_id: c.id,
        target_type: type,
        target_identifier: identifier
      )
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:collection_id, :target_type, :target_identifier]
      )
      |> case do
        {:ok, _} -> regenerate(c.id)
        error -> error
      end
    else
      false -> {:error, :ineligible}
      error -> error
    end
  end

  def add_member(_, _, _), do: {:error, :ineligible}

  def remove_member(secret, type, identifier) do
    with {:ok, c} <- manage(secret) do
      Repo.delete_all(
        from m in Member,
          where:
            m.collection_id == ^c.id and m.target_type == ^type and
              m.target_identifier == ^identifier
      )

      regenerate(c.id)
    end
  end

  def expire_unused(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@year, :second)
    {count, _} = Repo.delete_all(from c in Collection, where: c.last_used_at < ^cutoff)
    count
  end

  defp regenerate(id) do
    c = Repo.get!(Collection, id) |> Repo.preload(:members, force: true)

    title =
      case c.members do
        [] ->
          "Brussels follow collection"

        ms ->
          "Following #{length(ms)} public #{if length(ms) == 1, do: "resource", else: "resources"}"
      end

    c |> Ecto.Changeset.change(title: title, last_used_at: DateTime.utc_now()) |> Repo.update()
  end

  defp eligible?(:dossier, slug),
    do:
      Repo.exists?(
        from d in "dossiers", where: field(d, :slug) == ^slug and field(d, :status) == "active"
      )

  defp eligible?(:commune, slug),
    do: Repo.exists?(from c in "communes", where: field(c, :slug) == ^slug)

  defp eligible?(:legal_entity, number),
    do:
      Repo.exists?(
        from e in "legal_entities",
          where: field(e, :enterprise_number) == ^number and field(e, :status) == "active"
      )

  defp eligible?(:person, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id) do
      Repo.exists?(
        from p in "people",
          where: field(p, :id) == type(^uuid, :binary_id) and field(p, :status) == "active"
      ) and
        BrusselsWtf.Identity.PublicProjection.ever_public_person?(uuid)
    else
      _ -> false
    end
  end

  defp token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  defp hash(secret), do: :crypto.hash(:sha256, secret)
end
