defmodule BrusselsWtf.Accounts.Mail.File do
  @moduledoc false
  @behaviour BrusselsWtf.Accounts.Mail
  @impl true
  def deliver_magic_link(email, token, locale) do
    path = Application.fetch_env!(:brussels_wtf, :citizen_mail_file)
    File.write!(path, Jason.encode!(%{email: email, token: token, locale: locale}))
    :ok
  end
end
