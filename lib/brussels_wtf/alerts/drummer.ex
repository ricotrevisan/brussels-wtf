defmodule BrusselsWtf.Alerts.Drummer do
  @moduledoc """
  Sends an operator alert to Rico's Discord through Drummer's webhook on `openclaw`.

  Drummer's `brussels-wtf-alerts` route delivers the `message` field verbatim
  (`deliver_only`, no agent run). Requests use Hermes' generic HMAC V2 signature:
  `X-Webhook-Signature-V2` is the hex HMAC-SHA256 of `"<unix seconds>.<body>"` with
  `X-Webhook-Timestamp`. `X-Request-ID` makes a retried alert idempotent.

  Configure `DRUMMER_WEBHOOK_URL` and `DRUMMER_WEBHOOK_SECRET`. Without both, alerts
  are logged and reported as not sent, so the caller can try again later.
  """

  require Logger

  @max_message_bytes 1_800

  @spec notify(String.t(), String.t()) :: :ok | {:error, atom()}
  def notify(message, request_id) when is_binary(message) and is_binary(request_id) do
    case config() do
      %{url: url, secret: secret} when is_binary(url) and is_binary(secret) ->
        body = Jason.encode!(%{"message" => truncate(message)})
        timestamp = Integer.to_string(System.os_time(:second))

        signature =
          :crypto.mac(:hmac, :sha256, secret, timestamp <> "." <> body)
          |> Base.encode16(case: :lower)

        [
          url: url,
          body: body,
          headers: [
            {"content-type", "application/json"},
            {"x-webhook-timestamp", timestamp},
            {"x-webhook-signature-v2", signature},
            {"x-request-id", request_id}
          ],
          retry: false,
          redirect: false,
          receive_timeout: 10_000,
          connect_options: [timeout: 5_000]
        ]
        |> Keyword.merge(Map.get(config(), :req_options, []))
        |> Req.post()
        |> case do
          {:ok, %Req.Response{status: status}} when status in 200..299 ->
            :ok

          {:ok, %Req.Response{status: status}} ->
            Logger.warning("drummer alert rejected", http_status: status)
            {:error, :alert_rejected}

          {:error, _reason} ->
            Logger.warning("drummer alert transport failed")
            {:error, :alert_unreachable}
        end

      _missing ->
        Logger.warning("drummer alert not configured", alert: message)
        {:error, :alert_not_configured}
    end
  end

  defp truncate(message) when byte_size(message) <= @max_message_bytes, do: message
  defp truncate(message), do: binary_part(message, 0, @max_message_bytes) <> "…"

  defp config, do: Map.new(Application.get_env(:brussels_wtf, __MODULE__, []))
end
