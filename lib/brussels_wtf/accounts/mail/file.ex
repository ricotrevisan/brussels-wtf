defmodule BrusselsWtf.Accounts.Mail.File do
  @moduledoc false
  @behaviour BrusselsWtf.Accounts.Mail
  @impl true
  def deliver_magic_link(email, token, locale) do
    path = Application.fetch_env!(:brussels_wtf, :citizen_mail_file)
    File.write!(path, Jason.encode!(%{email: email, token: token, locale: locale}))
    :ok
  end

  @impl true
  def deliver_inactivity_warning(email, locale, subject, body, deletion_at, idempotency_key) do
    path = Application.fetch_env!(:brussels_wtf, :citizen_mail_file)

    File.write!(
      path,
      Jason.encode!(%{
        kind: "inactivity_warning",
        email: email,
        locale: locale,
        subject: subject,
        body: body,
        deletion_at: deletion_at,
        idempotency_key: idempotency_key
      })
    )

    :ok
  end
end
