defmodule BrusselsWtf.Accounts.Mail do
  @callback deliver_magic_link(String.t(), String.t(), String.t()) :: :ok
end
