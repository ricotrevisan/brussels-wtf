defmodule BrusselsWtf.Accounts.Citizen.Senders.SendMagicLink do
  @moduledoc false
  use AshAuthentication.Sender
  @impl true
  def send(user_or_email, token, _) do
    email =
      case user_or_email do
        %{email: email} -> to_string(email)
        email -> to_string(email)
      end

    locale = Process.get(:citizen_magic_link_locale, "en")
    :ok = BrusselsWtf.Accounts.record_outstanding_magic_link(email, token)
    link = "/citizen/magic-link?lang=#{locale}#token=#{URI.encode_www_form(token)}"
    Application.fetch_env!(:brussels_wtf, :citizen_mailer).deliver_magic_link(email, link, locale)
  end
end
