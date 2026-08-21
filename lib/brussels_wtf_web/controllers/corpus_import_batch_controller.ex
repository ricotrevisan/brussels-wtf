defmodule BrusselsWtfWeb.CorpusImportBatchController do
  use BrusselsWtfWeb, :controller

  def create(conn, %{"meeting_keys" => meeting_keys}) when is_binary(meeting_keys) do
    keys = String.split(meeting_keys, ~r/[\s,]+/, trim: true)
    BrusselsWtf.Corpus.Import.request!(keys, conn.assigns.current_review_actor)
    redirect(conn, to: "/review")
  rescue
    _error in [ArgumentError, Ash.Error.Invalid, Ash.Error.Query.NotFound] ->
      send_resp(conn, 422, "A valid sealed real-corpus allowlist is required")
  end

  def create(conn, _params),
    do: send_resp(conn, 422, "A valid sealed real-corpus allowlist is required")

  def prepare_coverage(conn, %{"id" => id}) do
    BrusselsWtf.Corpus.Import.prepare_coverage!(id, conn.assigns.current_review_actor)
    redirect(conn, to: "/review")
  rescue
    _error in [ArgumentError, Ash.Error.Invalid, Ash.Error.Query.NotFound] ->
      send_resp(conn, 422, "The complete normalized real corpus is required")
  end

  def refresh(conn, %{"id" => id}) do
    BrusselsWtf.Corpus.Import.refresh!(id, conn.assigns.current_review_actor)
    redirect(conn, to: "/review")
  rescue
    _error in [ArgumentError, Ash.Error.Invalid, Ash.Error.Query.NotFound] ->
      send_resp(conn, 422, "The real-corpus batch could not be refreshed")
  end
end
