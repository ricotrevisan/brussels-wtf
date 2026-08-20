defmodule BrusselsWtfWeb.PublicationActionController do
  use BrusselsWtfWeb, :controller

  alias BrusselsWtf.Council.PublicationLifecycle

  def factual_correction(conn, %{"page_id" => page_id, "bundles" => bundles, "notes" => notes}) do
    with {:ok, bundles} <- decode_map(bundles),
         {:ok, notes} <- decode_map(notes) do
      PublicationLifecycle.factual_correction!(
        page_id,
        bundles,
        notes,
        conn.assigns.current_review_actor
      )

      redirect_after_action(conn)
    else
      _error -> send_resp(conn, 422, "Valid correction bundles and notes are required")
    end
  rescue
    ArgumentError -> send_resp(conn, 422, "The factual correction is invalid")
  end

  def typography_correction(conn, %{
        "page_id" => page_id,
        "locale" => locale,
        "bundle" => bundle
      }) do
    with {:ok, bundle} <- decode_map(bundle) do
      PublicationLifecycle.typography_correction!(
        page_id,
        locale,
        bundle,
        conn.assigns.current_review_actor
      )

      redirect_after_action(conn)
    else
      _error -> send_resp(conn, 422, "A valid localized bundle is required")
    end
  rescue
    ArgumentError -> send_resp(conn, 422, "The typography correction is invalid")
  end

  def withdraw(conn, %{"page_id" => page_id, "reasons" => reasons}) do
    with {:ok, reasons} <- decode_map(reasons) do
      PublicationLifecycle.withdraw!(page_id, reasons, conn.assigns.current_review_actor)
      redirect_after_action(conn)
    else
      _error -> send_resp(conn, 422, "Valid localized withdrawal notices are required")
    end
  rescue
    ArgumentError -> send_resp(conn, 422, "The withdrawal is invalid")
  end

  def republish(conn, %{"page_id" => page_id}) do
    PublicationLifecycle.republish!(page_id, conn.assigns.current_review_actor)
    redirect_after_action(conn)
  rescue
    ArgumentError -> send_resp(conn, 422, "The meeting page cannot be republished")
  end

  defp decode_map(value) when is_map(value), do: {:ok, value}

  defp decode_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _error -> :error
    end
  end

  defp decode_map(_value), do: :error

  defp redirect_after_action(conn) do
    redirect(conn, to: conn.params["return_to"] || "/review")
  end
end
