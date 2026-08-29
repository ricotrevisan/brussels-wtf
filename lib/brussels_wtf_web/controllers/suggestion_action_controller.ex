defmodule BrusselsWtfWeb.SuggestionActionController do
  use BrusselsWtfWeb, :controller

  alias BrusselsWtf.Suggestions

  def reject(conn, %{"case_id" => case_id, "reason_code" => reason, "note" => note}) do
    moderate(conn, case_id, fn suggestion, actor ->
      Suggestions.reject(suggestion.id, %{reason_code: reason, note: note}, actor)
    end)
  end

  def reject(conn, _params), do: send_resp(conn, 422, "Required moderation fields are missing")

  def approve(conn, %{"case_id" => case_id, "verified_fact_id" => fact_id, "note" => note}) do
    moderate(conn, case_id, fn suggestion, actor ->
      Suggestions.approve(suggestion.id, fact_id, note, actor)
    end)
  end

  def approve(conn, _params), do: send_resp(conn, 422, "Required moderation fields are missing")

  defp moderate(conn, case_id, operation) do
    actor = conn.assigns.current_review_actor

    with {:ok, suggestion} <- Suggestions.get_for_review_case(case_id, actor),
         {:ok, _suggestion} <- operation.(suggestion, actor) do
      redirect(conn, to: "/review/cases/#{case_id}")
    else
      {:error, :already_decided} ->
        conn
        |> put_flash(:error, "This suggestion was already decided.")
        |> redirect(to: "/review/cases/#{case_id}")

      {:error, :fact_not_verified_or_matching} ->
        conn
        |> put_flash(:error, "The fact is not a current matching verified fact.")
        |> redirect(to: "/review/cases/#{case_id}")

      {:error, :not_found} ->
        send_resp(conn, 404, "Not found")

      {:error, _reason} ->
        send_resp(conn, 422, "The moderation action could not be completed")
    end
  end
end
