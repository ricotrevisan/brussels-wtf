defmodule BrusselsWtf.Communes.Adapter do
  @moduledoc """
  Discovery contract for one municipality's authoritative index.
  """

  @type locator :: %{
          required(:url) => String.t(),
          required(:meeting_identifier) => String.t(),
          required(:scheduled_on) => Date.t(),
          required(:role) => atom(),
          required(:language) => atom(),
          required(:observed_label) => String.t(),
          required(:parent_index_url) => String.t(),
          required(:item_identifier) => String.t() | nil,
          optional(:dossier_identifier) => String.t() | nil
        }

  @callback discover(html :: binary(), index_url :: String.t()) ::
              {:ok, [locator()]} | {:error, term()}
end
