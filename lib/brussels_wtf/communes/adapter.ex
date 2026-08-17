defmodule BrusselsWtf.Communes.Adapter do
  @moduledoc """
  Discovery contract for one municipality's authoritative index.
  """

  @type locator :: %{
          url: String.t(),
          meeting_identifier: String.t(),
          role: atom(),
          parent_index_url: String.t()
        }

  @callback discover(html :: binary(), index_url :: String.t()) ::
              {:ok, [locator()]} | {:error, term()}
end
