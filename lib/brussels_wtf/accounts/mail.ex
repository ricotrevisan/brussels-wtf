defmodule BrusselsWtf.Accounts.Mail do
  @moduledoc """
  Operational account mail boundary. Inactivity warnings are retried at least
  once after failures or expired claims. `idempotency_key` is stable for the
  citizen/sign-in-cycle/deadline identity. Adapters must deduplicate that key
  to avoid a duplicate after an ambiguous send-before-acknowledgement crash;
  SMTP or another transport without such support cannot provide exactly-once
  external receipt.
  """
  @callback deliver_magic_link(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback deliver_inactivity_warning(
              String.t(),
              String.t(),
              String.t(),
              String.t(),
              DateTime.t(),
              String.t()
            ) :: :ok | {:error, term()}
end
