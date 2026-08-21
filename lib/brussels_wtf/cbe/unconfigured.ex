defmodule BrusselsWtf.CBE.Unconfigured do
  @moduledoc false
  @behaviour BrusselsWtf.CBE

  @impl true
  def fetch_enterprise(_enterprise_number), do: {:error, :cbe_source_unconfigured}
end
