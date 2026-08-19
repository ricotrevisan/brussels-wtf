defmodule BrusselsWtf.Processors.Unimplemented do
  @moduledoc false
  @behaviour BrusselsWtf.Processors

  @impl true
  def extract(_meta, _bytes), do: {:error, :processor_unimplemented}

  @impl true
  def normalize(_extracted), do: {:error, :processor_unimplemented}
end
