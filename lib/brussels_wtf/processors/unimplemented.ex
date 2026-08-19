defmodule BrusselsWtf.Processors.Unimplemented do
  @moduledoc false
  @behaviour BrusselsWtf.Processors

  @impl true
  def extract(_meta, _bytes), do: {:error, :processor_unimplemented}

  @impl true
  def normalize(_extracted), do: {:error, :processor_unimplemented}

  @impl true
  def generate_fr(_normalized), do: {:error, :processor_unimplemented}

  @impl true
  def translate(_canonical, _locale), do: {:error, :processor_unimplemented}

  @impl true
  def coverage_metadata do
    %{
      processor_name: "unimplemented",
      processor_version: "0",
      config_hash: "sha256:unimplemented",
      provider_category: "unimplemented",
      model: nil,
      usage: %{}
    }
  end
end
