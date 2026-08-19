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
      inputs = action_inputs(action, note, params)

      apply(BrusselsWtf.Review, operation, [
        review_case,
        inputs,
        [actor: conn.assigns.current_review_actor]
      ])

      redirect(conn, to: "/review/cases/#{case_id}")
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  def create(conn, _params), do: send_resp(conn, 422, "Required review action fields are missing")

  defp action_inputs("retry", note, params) do
    %{
      note: note,
      processor_name: Map.get(params, "processor_name"),
      processor_version: Map.get(params, "processor_version"),
      config_hash: Map.get(params, "config_hash"),
      details: %{}
    }
  end

  defp action_inputs("reclassify", note, params),
    do: %{note: note, classification: Map.get(params, "classification")}

  defp action_inputs("relink", note, params) do
    %{
      note: note,
      target_record_id: Map.get(params, "target_record_id"),
      target_record_type: Map.get(params, "target_record_type")
    }
  end

  defp action_inputs("correct", note, params) do
    corrected_content =
      case Jason.decode(Map.get(params, "corrected_content", "")) do
        {:ok, value} when is_map(value) -> value
        _ -> %{}
      end

    %{note: note, corrected_content: corrected_content}
  end

  defp action_inputs("mark-unsupported", note, params),
    do: %{note: note, reason_code: Map.get(params, "reason_code")}
end
