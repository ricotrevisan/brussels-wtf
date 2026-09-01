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
  def deliver_inactivity_warning(email, locale, subject, body, deletion_at, idempotency_key) do
    table = ensure_dedup_table()

    case Application.get_env(:brussels_wtf, :inactivity_mail_failure) do
      :adapter_failure ->
        {:error, :injected_failure}

      _ ->
        if :ets.insert_new(table, {idempotency_key}) do
          if pid = Process.whereis(BrusselsWtf.Accounts.Mailbox),
            do: send(pid, {:inactivity_warning, email, locale, subject, body, deletion_at})
        end

        :ok
    end
  end

  @doc false
  def reset_inactivity_dedup do
    table = ensure_dedup_table()
    :ets.delete_all_objects(table)
    :ok
  end

  defp ensure_dedup_table do
    case :ets.whereis(__MODULE__) do
      :undefined ->
        try do
          :ets.new(__MODULE__, [:named_table, :public, :set])
        rescue
          ArgumentError -> __MODULE__
        end

      table ->
        table
    end
  end
end
