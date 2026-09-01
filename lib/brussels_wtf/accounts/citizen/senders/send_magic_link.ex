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

    :ok = BrusselsWtf.Accounts.record_outstanding_magic_link(email, token)
    Application.fetch_env!(:brussels_wtf, :citizen_mailer).deliver_magic_link(email, token, "en")
  end
end
