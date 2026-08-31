defmodule BrusselsWtfWeb.FollowCollectionController do
  use BrusselsWtfWeb, :controller
  alias BrusselsWtf.Follow

  def create(conn, _params) do
    case Follow.create_collection() do
      {:ok, _collection, secret} -> redirect(conn, to: "/collections/manage/#{secret}")
      _ -> send_resp(conn, 422, "Collection could not be created")
    end
  end

  def show(conn, %{"token" => token}) do
    case Follow.view(token) do
      {:ok, collection} -> render_collection(conn, collection, false)
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  def manage(conn, %{"secret" => secret}) do
    case Follow.manage(secret) do
      {:ok, collection} -> render_collection(conn, collection, true)
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  def update(conn, %{"secret" => secret, "visibility" => visibility}) do
    case Follow.set_visibility(secret, parse_visibility(visibility)) do
      {:ok, _} -> redirect(conn, to: "/collections/manage/#{secret}")
      _ -> send_resp(conn, 422, "Invalid collection change")
    end
  end

  def add(conn, %{"secret" => secret, "target_type" => type, "target_identifier" => id}) do
    case Follow.add_member(secret, parse_type(type), id) do
      {:ok, _} -> redirect(conn, to: "/collections/manage/#{secret}")
      _ -> send_resp(conn, 422, "This public resource cannot be added")
    end
  end

  def remove(conn, %{"secret" => secret, "target_type" => type, "target_identifier" => id}) do
    case Follow.remove_member(secret, parse_type(type), id) do
      {:ok, _} -> redirect(conn, to: "/collections/manage/#{secret}")
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  defp render_collection(conn, collection, management?) do
    conn =
      if collection.visibility == :public,
        do: conn,
        else: put_resp_header(conn, "x-robots-tag", "noindex, nofollow")

    members =
      Enum.map_join(collection.members, "", fn m ->
        "<li>#{escape(m.target_type)}: #{escape(m.target_identifier)}</li>"
      end)

    management =
      if management?,
        do: "<p>Management access</p><p>Visibility: #{collection.visibility}</p>",
        else: ""

    html(conn, """
    <!doctype html><html lang="en"><head><meta name="robots" content="#{if collection.visibility == :public, do: "index, follow", else: "noindex, nofollow"}"><title>#{collection.title}</title></head><body><main><h1>#{collection.title}</h1>#{management}<ul>#{members}</ul><p>This collection contains public resources only. It has no read state or notifications.</p></main></body></html>
    """)
  end

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp parse_type(v) when v in ~w(dossier person legal_entity commune),
    do: String.to_existing_atom(v)

  defp parse_type(_), do: :invalid
  defp parse_visibility(v) when v in ~w(public unlisted private), do: String.to_existing_atom(v)
  defp parse_visibility(_), do: :invalid
end
