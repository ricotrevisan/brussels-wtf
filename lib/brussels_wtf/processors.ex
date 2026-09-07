defmodule BrusselsWtf.Processors do
  @moduledoc """
  Extraction, normalization, and locale-generation adapters.

  Extraction/normalization and coverage processors use separate replaceable seams.
  Production starts with hash-pinned normalization and coverage contracts for one
  real Ixelles meeting; CI uses fixture-backed stubs and never depends on paid or
  nondeterministic model calls.
  """

  @callback extract(meta :: map(), bytes :: binary()) :: {:ok, map()} | {:error, term()}
  @callback normalize(extracted :: map()) :: {:ok, map()} | {:error, term()}

  def extract(meta, bytes), do: impl().extract(meta, bytes)
  def normalize(extracted), do: impl().normalize(extracted)

  def normalization_contract do
    processor = impl()

    contract =
      {processor, processor.module_info(:md5), BrusselsWtf.Corpus.Manifest.module_info(:md5),
       BrusselsWtf.Corpus.Manifest.digest()}

    contract |> :erlang.term_to_binary([:deterministic]) |> BrusselsWtf.Digest.sha256()
  end

  defp impl, do: Application.fetch_env!(:brussels_wtf, :processors)
end
