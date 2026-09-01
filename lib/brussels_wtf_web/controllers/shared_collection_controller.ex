defmodule BrusselsWtfWeb.SharedCollectionController do
  use BrusselsWtfWeb, :controller
  alias BrusselsWtf.{Accounts, Follow}

  @copy %{
    "en" => %{
      private: "Private collection",
      owner: "Collection sharing",
      grants: "People with view access",
      grant: "Grant view access",
      revoke: "Revoke",
      recipient: "Recipient email",
      transfer: "Offer ownership transfer",
      pending: "Ownership transfer",
      accept: "Accept transfer",
      reject: "Reject transfer",
      cancel: "Cancel offer",
      delete: "Delete collection",
      resolution: "Resolve collections before inactivity deletion",
      preselect_delete: "Delete automatically",
      preselect_transfer: "Transfer (takes effect only after acceptance)",
      revoke_choice: "Clear choice",
      unresolved: "Action required",
      view_only: "This share is view-only. Only the owner can change this collection.",
      empty: "No view grants."
    },
    "fr" => %{
      private: "Collection privée",
      owner: "Partage de la collection",
      grants: "Personnes ayant accès en lecture",
      grant: "Accorder l’accès en lecture",
      revoke: "Révoquer",
      recipient: "Adresse e-mail du destinataire",
      transfer: "Proposer le transfert de propriété",
      pending: "Transfert de propriété",
      accept: "Accepter le transfert",
      reject: "Refuser le transfert",
      cancel: "Annuler l’offre",
      delete: "Supprimer la collection",
      resolution: "Résolvez les collections avant la suppression pour inactivité",
      preselect_delete: "Supprimer automatiquement",
      preselect_transfer: "Transférer (effectif seulement après acceptation)",
      revoke_choice: "Effacer le choix",
      unresolved: "Action requise",
      view_only:
        "Ce partage est en lecture seule. Seul le propriétaire peut modifier cette collection.",
      empty: "Aucun accès en lecture."
    },
    "nl" => %{
      private: "Privécollectie",
      owner: "Collectie delen",
      grants: "Personen met leestoegang",
      grant: "Leestoegang geven",
      revoke: "Intrekken",
      recipient: "E-mailadres van ontvanger",
      transfer: "Eigendomsoverdracht aanbieden",
      pending: "Eigendomsoverdracht",
      accept: "Overdracht aanvaarden",
      reject: "Overdracht weigeren",
      cancel: "Aanbod annuleren",
      delete: "Collectie verwijderen",
      resolution: "Los collecties op vóór verwijdering wegens inactiviteit",
      preselect_delete: "Automatisch verwijderen",
      preselect_transfer: "Overdragen (pas geldig na aanvaarding)",
      revoke_choice: "Keuze wissen",
      unresolved: "Actie vereist",
      view_only: "Deze gedeelde collectie is alleen-lezen. Alleen de eigenaar kan ze wijzigen.",
      empty: "Geen leestoegang."
    }
  }

  def private_show(conn, %{"id" => id}) do
    with {:ok, citizen} <- citizen(conn),
         {:ok, collection} <- Follow.private_collection(id, citizen) do
      render_private(conn, collection)
    else
      _ -> private_not_found(conn)
    end
  end

  def owner_show(conn, %{"id" => id}) do
    with {:ok, citizen} <- citizen(conn),
         {:ok, collection} <- Follow.owner_collection(citizen, id),
         {:ok, grants} <- Follow.list_private_grants(citizen, id) do
      render_owner(conn, collection, grants)
    else
      _ -> private_not_found(conn)
    end
  end

  def grant(conn, %{"id" => id, "recipient_id" => recipient}),
    do: owner_action(conn, id, &Follow.grant_private_view(&1, id, recipient))

  def revoke(conn, %{"id" => id, "grant_id" => grant}),
    do: owner_action(conn, id, &Follow.revoke_private_view(&1, id, grant))

  def offer_transfer(conn, %{"id" => id, "recipient_id" => recipient}) do
    with {:ok, c} <- citizen(conn),
         {:ok, _offer, _token} <- Follow.offer_collection_transfer(c, id, recipient),
         do: redirect(conn, to: "/citizen/collections/#{id}"),
         else: (_ -> private_not_found(conn))
  end

  def cancel_transfer(conn, %{"id" => id, "offer_id" => offer}),
    do: owner_action(conn, id, &Follow.cancel_collection_transfer(&1, offer))

  def delete_collection(conn, %{"id" => id}),
    do:
      owner_action(conn, id, &Follow.delete_owned_collection(&1, id), "/citizen/account/deletion")

  def transfer_show(conn, %{"id" => id}) do
    with {:ok, citizen} <- citizen(conn),
         {:ok, offer} <- Follow.collection_transfer_offer(citizen, id) do
      c = copy(conn)
      csrf = csrf()

      html_private(
        conn,
        c.pending,
        "<h1>#{c.pending}</h1><p>#{escape(offer.collection_id)}</p>" <>
          form("/citizen/collection-transfers/#{escape(id)}/accept", c.accept, csrf) <>
          form("/citizen/collection-transfers/#{escape(id)}/reject", c.reject, csrf)
      )
    else
      _ -> private_not_found(conn)
    end
  end

  def accept_transfer(conn, %{"id" => id}),
    do: transfer_action(conn, id, &Follow.accept_collection_transfer/2)

  def reject_transfer(conn, %{"id" => id}),
    do: transfer_action(conn, id, &Follow.decline_collection_transfer/2)

  def select_inactivity_resolution(conn, %{"id" => id, "choice" => choice})
      when choice in ["delete", "transfer"] do
    with {:ok, c} <- citizen(conn),
         {:ok, _} <- Follow.select_inactivity_resolution(c, id, String.to_existing_atom(choice)),
         do: redirect(conn, to: "/citizen/account/deletion"),
         else: (_ -> private_not_found(conn))
  end

  def revoke_inactivity_resolution(conn, %{"id" => id}) do
    with {:ok, c} <- citizen(conn),
         {:ok, _} <- Follow.revoke_inactivity_resolution(c, id),
         do: redirect(conn, to: "/citizen/account/deletion"),
         else: (_ -> private_not_found(conn))
  end

  def deletion_resolution(conn, _) do
    with {:ok, citizen} <- citizen(conn),
         {:ok, collections} <- Follow.owner_collections(citizen),
         {:ok, resolutions} <- Follow.inactivity_resolutions(citizen) do
      c = copy(conn)
      csrf = csrf()

      rows =
        Enum.map_join(collections, "", fn item ->
          collection = Map.get(item, :collection, item)

          choice = Enum.find(resolutions, &(&1.collection_id == collection.id))

          controls =
            if collection.visibility == :private do
              "<span>#{c.preselect_delete}</span>"
            else
              selected = if choice, do: escape(choice.choice), else: c.unresolved

              "<strong data-resolution-status>#{selected}</strong>" <>
                choice_form(collection.id, :delete, c.preselect_delete, csrf) <>
                choice_form(collection.id, :transfer, c.preselect_transfer, csrf) <>
                if(choice,
                  do:
                    form(
                      "/citizen/collections/#{escape(collection.id)}/inactivity-resolution",
                      c.revoke_choice,
                      csrf,
                      "delete"
                    ),
                  else: ""
                )
            end

          "<li data-collection-blocker>#{escape(collection.title)} (#{escape(collection.visibility)})" <>
            ~s(<a href="/citizen/collections/#{escape(collection.id)}">#{c.owner}</a>) <>
            controls <> "</li>"
        end)

      html_private(conn, c.resolution, "<h1>#{c.resolution}</h1><ul>#{rows}</ul>")
    else
      _ -> unauthorized(conn)
    end
  end

  defp render_private(conn, collection) do
    c = copy(conn)
    members = members(collection)

    html_private(
      conn,
      collection.title,
      "<h1>#{escape(collection.title)}</h1><p>#{c.view_only}</p><ul>#{members}</ul>"
    )
  end

  defp render_owner(conn, collection, grants) do
    c = copy(conn)
    csrf = csrf()

    grant_rows =
      if grants == [],
        do: "<li>#{c.empty}</li>",
        else:
          Enum.map_join(grants, "", fn grant ->
            label = Map.get(grant, :email, Map.get(grant, :citizen_id, ""))
            target = Map.get(grant, :id)

            "<li>#{escape(label)}" <>
              form(
                "/citizen/collections/#{escape(collection.id)}/grants/#{escape(target)}",
                c.revoke,
                csrf,
                "delete"
              ) <> "</li>"
          end)

    body =
      "<h1>#{escape(collection.title)}</h1><h2>#{c.grants}</h2><ul>#{grant_rows}</ul>" <>
        input_form(
          "/citizen/collections/#{escape(collection.id)}/grants",
          c.recipient,
          "recipient_id",
          c.grant,
          csrf
        ) <>
        input_form(
          "/citizen/collections/#{escape(collection.id)}/transfer-offers",
          c.recipient,
          "recipient_id",
          c.transfer,
          csrf
        ) <>
        form("/citizen/collections/#{escape(collection.id)}", c.delete, csrf, "delete")

    html_private(conn, c.owner, body)
  end

  defp owner_action(conn, id, fun, to \\ nil) do
    with {:ok, c} <- citizen(conn),
         result when result == :ok or elem(result, 0) == :ok <- fun.(c),
         do: redirect(conn, to: to || "/citizen/collections/#{id}"),
         else: (_ -> private_not_found(conn))
  end

  defp transfer_action(conn, id, fun) do
    with {:ok, c} <- citizen(conn),
         {:ok, _} <- fun.(c, id),
         do: redirect(conn, to: "/citizen/collections/#{id}"),
         else: (_ -> private_not_found(conn))
  end

  defp citizen(conn), do: Accounts.authenticate_session(get_session(conn, :citizen_session_id))
  defp copy(conn), do: Map.fetch!(@copy, conn.assigns.locale)
  defp csrf, do: Plug.CSRFProtection.get_csrf_token()

  defp members(c),
    do:
      Enum.map_join(
        Map.get(c, :members, []),
        "",
        &"<li>#{escape(&1.target_type)}: #{escape(&1.target_identifier)}</li>"
      )

  defp form(action, label, csrf, method \\ "post"),
    do:
      ~s(<form method="post" action="#{action}"><input type="hidden" name="_csrf_token" value="#{csrf}">#{if method != "post", do: ~s(<input type="hidden" name="_method" value="#{method}">), else: ""}<button>#{label}</button></form>)

  defp choice_form(id, choice, label, csrf),
    do:
      ~s(<form method="post" action="/citizen/collections/#{escape(id)}/inactivity-resolution"><input type="hidden" name="_csrf_token" value="#{csrf}"><input type="hidden" name="choice" value="#{choice}"><button>#{label}</button></form>)

  defp input_form(action, label, name, button, csrf),
    do:
      ~s(<form method="post" action="#{action}"><input type="hidden" name="_csrf_token" value="#{csrf}"><label>#{label} <input type="text" name="#{name}" required></label><button>#{button}</button></form>)

  defp html_private(conn, title, body),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("x-robots-tag", "noindex, nofollow")
      |> html(
        ~s(<!doctype html><html lang="#{conn.assigns.locale}"><head><meta name="robots" content="noindex, nofollow"><title>#{escape(title)}</title></head><body><main>#{body}</main></body></html>)
      )

  defp private_not_found(conn),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-robots-tag", "noindex, nofollow")
      |> send_resp(404, "Not found")

  defp unauthorized(conn),
    do: conn |> put_resp_header("cache-control", "no-store") |> send_resp(401, "")

  defp escape(v),
    do: v |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
