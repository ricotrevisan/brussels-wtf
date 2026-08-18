defmodule BrusselsWtfWeb.ReviewActionController do
  use BrusselsWtfWeb, :controller

  @actions %{
    "retry" => :retry_review_case!,
    "reclassify" => :reclassify_review_case!,
    "relink" => :relink_review_case!,
    "correct" => :correct_review_case!,
    "mark-unsupported" => :mark_review_case_unsupported!
  }

  def create(conn, %{"case_id" => case_id, "action" => action, "note" => note} = params) do
    with operation when not is_nil(operation) <- Map.get(@actions, action),
         review_case <-
           BrusselsWtf.Review.get_review_case!(case_id, actor: conn.assigns.current_review_actor) do
      details = %{"instruction" => Map.get(params, "details", "")}

      apply(BrusselsWtf.Review, operation, [
        review_case,
        %{note: note, details: details},
        [actor: conn.assigns.current_review_actor]
      ])

      redirect(conn, to: "/review/cases/#{case_id}")
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  def create(conn, _params), do: send_resp(conn, 422, "A reviewer note is required")
end
