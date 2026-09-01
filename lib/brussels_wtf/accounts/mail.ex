defmodule BrusselsWtf.Accounts.Mail do
  @callback deliver_magic_link(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback deliver_inactivity_warning(
              String.t(),
              String.t(),
              String.t(),
              String.t(),
              DateTime.t()
            ) :: :ok | {:error, term()}
end
