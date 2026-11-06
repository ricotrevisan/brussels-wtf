defmodule BrusselsWtf.Accounts.Mail.Cloudflare do
  @moduledoc """
  Sends citizen account mail through the Cloudflare Email Service REST API.

  Cloudflare's send API has no idempotency key, so a crash between the send and
  the recorded outcome can repeat one inactivity warning. A duplicate warning is
  harmless; a missed one is not.

  The `from` address must belong to a sending domain onboarded for Email Sending
  in the configured Cloudflare account.
  """
  @behaviour BrusselsWtf.Accounts.Mail

  require Logger

  @base_url "https://api.cloudflare.com/client/v4"

  @magic_link_copy %{
    "fr" =>
      {"Votre lien de connexion à brussels.wtf",
       "Ouvrez ce lien pour vous connecter. Il expire dans 15 minutes et ne fonctionne qu’une fois.",
       "Si vous n’avez pas demandé ce lien, ignorez ce message."},
    "nl" =>
      {"Uw aanmeldlink voor brussels.wtf",
       "Open deze link om u aan te melden. Hij verloopt na 15 minuten en werkt maar één keer.",
       "Hebt u deze link niet aangevraagd? Negeer dan dit bericht."},
    "en" =>
      {"Your brussels.wtf sign-in link",
       "Open this link to sign in. It expires in 15 minutes and works once.",
       "If you did not ask for this link, ignore this message."}
  }

  @impl true
  def deliver_magic_link(email, link, locale) do
    {subject, intro, outro} = Map.get(@magic_link_copy, locale, @magic_link_copy["en"])
    url = BrusselsWtfWeb.Endpoint.url() <> link

    send_mail(email, subject, "#{intro}\n\n#{url}\n\n#{outro}\n", :magic_link)
  end

  @impl true
  def deliver_inactivity_warning(email, _locale, subject, body, _deletion_at, _idempotency_key) do
    send_mail(to_string(email), subject, body <> "\n", :inactivity_warning)
  end

  defp send_mail(to, subject, text, kind) do
    config = Application.fetch_env!(:brussels_wtf, __MODULE__)

    request =
      Req.new(
        url: "#{@base_url}/accounts/#{config[:account_id]}/email/sending/send",
        auth: {:bearer, config[:api_token]},
        retry: false,
        receive_timeout: 15_000
      )
      |> Req.merge(Keyword.get(config, :req_options, []))

    body = %{from: config[:from], to: [to], subject: subject, text: text}

    case Req.post(request, json: body) do
      {:ok, %Req.Response{status: status, body: %{"success" => true, "result" => result}}}
      when status in 200..299 ->
        if to in List.wrap(result["permanent_bounces"]) or
             to in List.wrap(result["suppressed_recipients"]) do
          failed(kind, :recipient_rejected)
        else
          :ok
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        failed(kind, {:http, status, errors(body)})

      {:error, exception} ->
        failed(kind, {:transport, Exception.message(exception)})
    end
  end

  defp errors(%{"errors" => errors}) when is_list(errors),
    do: Enum.map(errors, &Map.take(&1, ["code", "message"]))

  defp errors(_), do: :unexpected_body

  # Never log the recipient address.
  defp failed(kind, reason) do
    Logger.error("citizen_mail_delivery_failed kind=#{kind} reason=#{inspect(reason)}")
    {:error, reason}
  end
end
