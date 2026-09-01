defmodule BrusselsWtf.Accounts.Mail.Memory do
  @moduledoc "Non-network magic-link adapter used by the project harness."
  @behaviour BrusselsWtf.Accounts.Mail
  @impl true
  def deliver_magic_link(email, token, locale) do
    if pid = Process.whereis(BrusselsWtf.Accounts.Mailbox),
      do: send(pid, {:magic_link, email, token, locale})

    :ok
  end

  @impl true
  def deliver_inactivity_warning(email, locale, subject, body, deletion_at) do
    if pid = Process.whereis(BrusselsWtf.Accounts.Mailbox),
      do: send(pid, {:inactivity_warning, email, locale, subject, body, deletion_at})

    :ok
  end
end
