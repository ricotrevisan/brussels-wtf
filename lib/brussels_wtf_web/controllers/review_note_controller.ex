defmodule BrusselsWtfWeb.ReviewNoteController do
  use BrusselsWtfWeb, :controller

  def create(conn, %{"case_id" => case_id, "body" => body}) do
    review_case =
      BrusselsWtf.Review.get_review_case!(case_id, actor: conn.assigns.current_review_actor)

    BrusselsWtf.Review.add_review_note!(
      %{review_case_id: review_case.id, body: body},
      actor: conn.assigns.current_review_actor
    )

    redirect(conn, to: "/review/cases/#{case_id}")
  end

  def create(conn, _params), do: send_resp(conn, 422, "A note is required")
end
