defmodule BrusselsWtfWeb.FollowCollectionController do
  use BrusselsWtfWeb, :controller
  alias BrusselsWtf.Follow

  @session_key :follow_management_collection_id

  def create(conn, _params) do
    case Follow.create_collection() do
      {:ok, _collection, secret} ->
        management_url =
          "/collections/manage-capability#capability=" <> URI.encode_www_form(secret)

        conn
        |> private_headers()
        |> html("""
        <!doctype html><html lang="en"><head><meta name="referrer" content="no-referrer"><meta name="robots" content="noindex, nofollow"><title>Collection created</title></head><body>
        <main><h1>Collection created</h1><p>Save this management link. It is the only way to recover management access.</p><p><a id="management-link" href="#{management_url}">Manage collection</a></p></main>
        </body></html>
        """)

      _ ->
        send_resp(conn, 422, "Collection could not be created")
    end
  end

  def bootstrap(conn, _params) do
    csrf = Plug.CSRFProtection.get_csrf_token()

    conn
    |> private_headers()
    |> html("""
    <!doctype html><html lang="en"><head><meta name="referrer" content="no-referrer"><meta name="robots" content="noindex, nofollow"><title>Open collection management</title></head><body>
    <main><p>Opening collection management…</p></main>
    <script>
    (() => {
      const capability = new URLSearchParams(location.hash.slice(1)).get("capability");
      history.replaceState(null, "", location.pathname);
      if (!capability) { document.querySelector("p").textContent = "Invalid management link"; return; }
      fetch(location.pathname, {method: "POST", credentials: "same-origin", headers: {"x-csrf-token": "#{csrf}", "x-follow-capability": capability}})
        .then(response => { if (!response.ok) throw new Error("invalid"); location.replace("/collections/manage"); })
        .catch(() => { document.querySelector("p").textContent = "Invalid management link"; });
    })();
    </script></body></html>
    """)
  end

  def exchange(conn, _params) do
    secret = conn |> get_req_header("x-follow-capability") |> List.first()

    case Follow.exchange(secret) do
      {:ok, collection} ->
        conn
        |> configure_session(renew: true)
        |> put_session(@session_key, collection.id)
        |> private_headers()
        |> send_resp(204, "")

      _ ->
        conn |> private_headers() |> send_resp(404, "Not found")
    end
  end

  def show(conn, %{"token" => token}) do
    case Follow.view(token) do
      {:ok, collection} -> render_collection(conn, collection, false)
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  def manage(conn, _params) do
    with {:ok, id} <- management_id(conn),
         {:ok, collection} <- Follow.manage_session(id) do
      render_collection(conn, collection, true)
    else
      _ -> conn |> private_headers() |> send_resp(404, "Not found")
    end
  end

  def update(conn, %{"visibility" => visibility}) do
    with {:ok, id} <- management_id(conn),
         {:ok, _} <- Follow.set_visibility_session(id, parse_visibility(visibility)) do
      conn |> private_headers() |> redirect(to: "/collections/manage")
    else
      _ -> conn |> private_headers() |> send_resp(422, "Invalid collection change")
    end
  end

  def add(conn, %{"target_type" => type, "target_identifier" => identifier}) do
    with {:ok, id} <- management_id(conn),
         {:ok, _} <- Follow.add_member_session(id, parse_type(type), identifier) do
      conn |> private_headers() |> redirect(to: "/collections/manage")
    else
      _ -> conn |> private_headers() |> send_resp(422, "This public resource cannot be added")
    end
  end

  def remove(conn, %{"target_type" => type, "target_identifier" => identifier}) do
    with {:ok, id} <- management_id(conn),
         {:ok, _} <- Follow.remove_member_session(id, parse_type(type), identifier) do
      conn |> private_headers() |> redirect(to: "/collections/manage")
    else
      _ -> conn |> private_headers() |> send_resp(404, "Not found")
    end
  end

  defp management_id(conn) do
    case get_session(conn, @session_key) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp render_collection(conn, collection, management?) do
    conn =
      conn
      |> put_resp_header("referrer-policy", "no-referrer")
      |> then(fn conn ->
        if collection.visibility == :public and not management?,
          do: conn,
          else: put_resp_header(conn, "x-robots-tag", "noindex, nofollow")
      end)
      |> then(fn conn -> if management?, do: private_headers(conn), else: conn end)

    csrf_token = Plug.CSRFProtection.get_csrf_token()

    members =
      Enum.map_join(collection.members, "", fn member ->
        remove =
          if management?,
            do: """
              <form action="/collections/manage/members" method="post">
                <input type="hidden" name="_csrf_token" value="#{csrf_token}"><input type="hidden" name="_method" value="delete">
                <input type="hidden" name="target_type" value="#{escape(member.target_type)}"><input type="hidden" name="target_identifier" value="#{escape(member.target_identifier)}">
                <button type="submit">Remove</button>
              </form>
            """,
            else: ""

        "<li>#{escape(member.target_type)}: #{escape(member.target_identifier)}#{remove}</li>"
      end)

    management =
      if management?,
        do: """
          <p>Management access</p><p><a href="/collections/#{escape(collection.view_token)}">Public view</a></p>
          <form action="/collections/manage" method="post"><input type="hidden" name="_csrf_token" value="#{csrf_token}"><input type="hidden" name="_method" value="patch">
            <label>Visibility <select name="visibility">#{visibility_options(collection.visibility)}</select></label><button type="submit">Change visibility</button>
          </form>
          <form action="/collections/manage/members" method="post"><input type="hidden" name="_csrf_token" value="#{csrf_token}">
            <label>Resource type <select name="target_type"><option value="dossier">Dossier</option><option value="person">Person</option><option value="legal_entity">Legal entity</option><option value="commune">Commune</option></select></label>
            <label>Stable public identifier <input name="target_identifier" required></label><button type="submit">Add public resource</button>
          </form>
        """,
        else: ""

    html(conn, """
    <!doctype html><html lang="en"><head><meta name="robots" content="#{if collection.visibility == :public and not management?, do: "index, follow", else: "noindex, nofollow"}"><title>#{escape(collection.title)}</title></head><body><main><h1>#{escape(collection.title)}</h1>#{management}<ul>#{members}</ul><p>This collection contains public resources only. It has no read state or notifications.</p></main></body></html>
    """)
  end

  defp private_headers(conn),
    do:
      conn
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-robots-tag", "noindex, nofollow")

  defp visibility_options(current),
    do:
      Enum.map_join([:public, :unlisted, :private], fn v ->
        "<option value=\"#{v}\"#{if v == current, do: " selected", else: ""}>#{v}</option>"
      end)

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp parse_type(v) when v in ~w(dossier person legal_entity commune),
    do: String.to_existing_atom(v)

  defp parse_type(_), do: :invalid
  defp parse_visibility(v) when v in ~w(public unlisted private), do: String.to_existing_atom(v)
  defp parse_visibility(_), do: :invalid
end
