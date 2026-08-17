defmodule BrusselsWtf.Communes.Adapter do
  @moduledoc """
  Discovery contract for one municipality's authoritative index.
  """

  @type locator :: %{
          url: String.t(),
          meeting_identifier: String.t(),
          scheduled_on: Date.t(),
          role: atom(),
          language: atom(),
          observed_label: String.t(),
          parent_index_url: String.t(),
          item_identifier: String.t() | nil
        }

  @callback discover(html :: binary(), index_url :: String.t()) ::
              {:ok, [locator()]} | {:error, term()}
end
