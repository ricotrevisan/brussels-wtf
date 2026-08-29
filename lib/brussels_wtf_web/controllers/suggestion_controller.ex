defmodule BrusselsWtfWeb.SuggestionController do
  use BrusselsWtfWeb, :controller

  alias BrusselsWtf.Suggestions
  alias BrusselsWtfWeb.SuggestionClientAddress

  def create(conn, params) do
    if Suggestions.enabled?() do
      attrs = %{
        kind: safe_kind(params),
        subject_type: subject_type(params),
        subject_reference: subject_reference(params),
        body: Map.get(params, "body"),
        contact: Map.get(params, "contact"),
        website: Map.get(params, "website")
      }

      case Suggestions.submit(attrs, client_address: SuggestionClientAddress.get(conn)) do
        {:ok, :accepted} ->
          generic_success(conn)

        {:error, reason} when reason in [:invalid_submission, :rate_limited] ->
          generic_success(conn)

        {:error, reason} ->
          raise "suggestion intake failed: #{inspect(reason)}"
      end
    else
      send_resp(conn, 404, not_found_text(conn.assigns.locale))
    end
  end

  defp generic_success(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(:accepted, accepted_text(conn.assigns.locale))
  end

  defp accepted_text("fr"),
    do:
      "Merci. Si elle peut être examinée, la soumission entrera dans le flux de preuves privé.\n"

  defp accepted_text("nl"),
    do: "Dank u. Als ze kan worden bekeken, gaat de inzending naar de private bewijsworkflow.\n"

  defp accepted_text(_locale),
    do:
      "Thank you. If it can be reviewed, the submission will enter the private evidence workflow.\n"

  defp not_found_text("fr"), do: "Introuvable"
  defp not_found_text("nl"), do: "Niet gevonden"
  defp not_found_text(_locale), do: "Not found"

  defp safe_kind(%{"kind" => "ownership"}), do: :ownership
  defp safe_kind(%{"kind" => "correction"}), do: :correction
  defp safe_kind(_), do: :invalid

  defp subject_type(%{"enterprise_number" => _}), do: :legal_entity
  defp subject_type(%{"id" => _}), do: :person
  defp subject_type(_), do: :invalid
  defp subject_reference(%{"enterprise_number" => number}), do: number
  defp subject_reference(%{"id" => id}), do: id
  defp subject_reference(_), do: nil
end
