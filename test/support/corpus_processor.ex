defmodule BrusselsWtf.Test.CorpusProcessor do
  @moduledoc false
  @behaviour BrusselsWtf.Processors

  @impl true
  def extract(meta, bytes), do: BrusselsWtf.Processors.Stub.extract(meta, bytes)

  @impl true
  def normalize(extracted), do: BrusselsWtf.Processors.RecordedCorpus.normalize(extracted)
end
