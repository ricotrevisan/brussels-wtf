defmodule BrusselsWtfWeb.PollController do
  use BrusselsWtfWeb, :controller

  @target_types %{
    "commune" => :commune,
    "meeting" => :meeting,
    "index" => :index,
    "locator" => :locator
  }

  def create(
        conn,
        %{"operation" => operation, "target_type" => target_type, "target_id" => target_id}
      )
      when operation in ["poll-now", "backfill"] do
    with type when not is_nil(type) <- Map.get(@target_types, target_type) do
      target = %{type: type, id: target_id}
      actor = conn.assigns.current_review_actor

      case request(operation, target, actor) do
        :ok -> redirect(conn, to: "/review")
        {:error, :invalid_target} -> send_resp(conn, 422, "Invalid poll target")
      end
    else
      _ -> send_resp(conn, 422, "Invalid poll target")
    end
  end

  def create(conn, _params), do: send_resp(conn, 422, "Required poll fields are missing")

  defp request(operation, target, actor) do
    case operation do
      "poll-now" -> BrusselsWtf.Ingestion.request_poll_now!(target, actor: actor)
      "backfill" -> BrusselsWtf.Ingestion.request_backfill!(target, actor: actor)
    end

    :ok
  rescue
    _error in [Ash.Error.Invalid, Ash.Error.Query.NotFound] -> {:error, :invalid_target}
  end
end
