defmodule BrusselsWtfWeb.ReviewActionController do
  use BrusselsWtfWeb, :controller

  @actions %{
    "retry" => :retry_review_case!,
    "reclassify" => :reclassify_review_case!,
    "relink" => :relink_review_case!,
    "correct" => :correct_review_case!,
    "mark-unsupported" => :mark_review_case_unsupported!
  }

  @dossier_actions ~w(confirm-dossier-link remove-dossier-link merge-dossiers split-dossier relink-dossier)

  def create(conn, %{"case_id" => case_id, "action" => action, "note" => note} = params) do
    actor = conn.assigns.current_review_actor

    cond do
      operation = Map.get(@actions, action) ->
        review_case = BrusselsWtf.Review.get_review_case!(case_id, actor: actor)
        inputs = action_inputs(action, note, params)
        apply(BrusselsWtf.Review, operation, [review_case, inputs, [actor: actor]])
        redirect(conn, to: "/review/cases/#{case_id}")

      action in @dossier_actions ->
        perform_dossier_action!(action, case_id, note, params, actor)
        redirect(conn, to: "/review/cases/#{case_id}")

      true ->
        send_resp(conn, 404, "Not found")
    end
  end

  def create(conn, _params), do: send_resp(conn, 422, "Required review action fields are missing")

  defp action_inputs("retry", note, _params), do: %{note: note, details: %{}}

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

  defp perform_dossier_action!("confirm-dossier-link", case_id, note, params, actor) do
    BrusselsWtf.Council.Dossiers.confirm_link!(params["dossier_link_id"], case_id, note, actor)
  end

  defp perform_dossier_action!("remove-dossier-link", case_id, note, params, actor) do
    BrusselsWtf.Council.Dossiers.remove_link!(params["dossier_link_id"], case_id, note, actor)
  end

  defp perform_dossier_action!("merge-dossiers", case_id, note, params, actor) do
    BrusselsWtf.Council.Dossiers.merge!(
      params["source_dossier_id"],
      params["target_dossier_id"],
      case_id,
      note,
      actor
    )
  end

  defp perform_dossier_action!("split-dossier", case_id, note, params, actor) do
    link_ids =
      params
      |> Map.get("dossier_link_ids", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    BrusselsWtf.Council.Dossiers.split!(
      params["source_dossier_id"],
      link_ids,
      %{slug: params["new_dossier_slug"], title: params["new_dossier_title"]},
      case_id,
      note,
      actor
    )
  end

  defp perform_dossier_action!("relink-dossier", case_id, note, params, actor) do
    BrusselsWtf.Council.Dossiers.relink!(
      params["dossier_link_id"],
      params["target_dossier_id"],
      case_id,
      note,
      actor
    )
  end
end
