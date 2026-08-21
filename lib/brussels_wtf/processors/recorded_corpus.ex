defmodule BrusselsWtf.Processors.RecordedCorpus do
  @moduledoc "Hash-pinned normalizer for the bounded issue-33 real corpus."
  @behaviour BrusselsWtf.Processors

  @impl true
  def extract(_meta, _bytes), do: {:error, :processor_unimplemented}

  @impl true
  defdelegate normalize(extracted), to: BrusselsWtf.Corpus.Manifest
end
