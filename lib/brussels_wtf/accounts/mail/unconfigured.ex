defmodule BrusselsWtf.Accounts.Mail.Unconfigured do
  @moduledoc """
  Production adapter when no mail transport is configured. Every send fails, so
  inactivity warnings are recorded as failed and retried instead of being
  reported as delivered.
  """
  @behaviour BrusselsWtf.Accounts.Mail

  require Logger

  @impl true
  def deliver_magic_link(_email, _link, _locale), do: failed(:magic_link)

  @impl true
  def deliver_inactivity_warning(_email, _locale, _subject, _body, _deletion_at, _key),
    do: failed(:inactivity_warning)

  defp failed(kind) do
    Logger.error("citizen_mail_delivery_failed kind=#{kind} reason=:mail_not_configured")
    {:error, :mail_not_configured}
  end
end
