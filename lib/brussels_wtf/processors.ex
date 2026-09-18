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

  @doc """
  Optional provenance digest over every module whose code can change normalized output.

  A composite processor defines it so the normalization contract follows the code it
  delegates to, not only the configured module itself.
  """
  @callback normalization_digest() :: binary()

  @optional_callbacks normalization_digest: 0

  def extract(meta, bytes), do: impl().extract(meta, bytes)
  def normalize(extracted), do: impl().normalize(extracted)

  def normalization_contract do
    processor = impl()

    contract =
      {processor, processor.module_info(:md5), BrusselsWtf.Corpus.Manifest.module_info(:md5),
       BrusselsWtf.Corpus.Manifest.digest(),
       BrusselsWtf.Corpus.Manifest.digest("current-20260911")}

    # Only a composite processor widens the contract; every module without the
    # optional callback keeps the exact recorded contract shape.
    contract =
      if function_exported?(processor, :normalization_digest, 0),
        do: :erlang.append_element(contract, processor.normalization_digest()),
        else: contract

    contract |> :erlang.term_to_binary([:deterministic]) |> BrusselsWtf.Digest.sha256()
  end

  defp impl, do: Application.fetch_env!(:brussels_wtf, :processors)
end
