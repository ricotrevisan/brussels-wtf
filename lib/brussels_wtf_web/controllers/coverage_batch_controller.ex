defmodule BrusselsWtfWeb.CoverageBatchController do
  use BrusselsWtfWeb, :controller

  def create(conn, %{"meeting_ids" => meeting_ids}) when is_binary(meeting_ids) do
    ids = String.split(meeting_ids, ~r/[\s,]+/, trim: true)

    BrusselsWtf.Council.request_coverage_batch!(ids,
      actor: conn.assigns.current_review_actor
    )

    redirect(conn, to: "/review")
  rescue
    _error in [ArgumentError, Ash.Error.Invalid, Ash.Error.Query.NotFound] ->
      send_resp(conn, 422, "A valid bounded meeting allowlist is required")
  end

  def create(conn, _params),
    do: send_resp(conn, 422, "A valid bounded meeting allowlist is required")
end
