defmodule BrusselsWtf.Processors.Council do
  @moduledoc """
  Composite normalization processor: recorded corpus first, commune normalizer second.

  The hash-pinned recorded corpus stays authoritative. A source version whose SHA-256
  the manifest already knows is normalized by the manifest contract and never reaches a
  commune parser. Only an unknown hash is delegated to the commune normalizer that the
  explicit discovery context names, and only when that module is present in the running
  release. Anything else fails closed with `:processor_unimplemented`, so the ingestion
  pipeline opens a review case instead of guessing an identity or an outcome.

  Extraction is unchanged: born-digital text still comes from `BrusselsWtf.PDF.Processor`,
  and the `extract/2` callback of the processor behaviour stays unimplemented as before.
  """

  @behaviour BrusselsWtf.Processors

  @commune_normalizers %{
    "city-of-brussels" => BrusselsWtf.Processors.CityOfBrusselsCouncil,
    "forest" => BrusselsWtf.Processors.ForestCouncil,
    "ixelles" => BrusselsWtf.Processors.IxellesCouncil,
    "uccle" => BrusselsWtf.Processors.UccleCouncil
  }

  # Final records read differently from agendas, so a commune's minutes reader is named
  # by the same explicit discovery context. It also widens the normalization contract.
  @minutes_normalizers %{"ixelles" => BrusselsWtf.Processors.IxellesMinutes}

  @impl true
  def extract(_meta, _bytes), do: {:error, :processor_unimplemented}

  @doc """
  Stable digest over the code whose bytes can change normalized output.

  It covers this module plus every configured commune normalizer. An absent commune
  normalizer still contributes a deterministic marker, so the contract only moves
  when the deployed code moves.
  """
  @impl true
  def normalization_digest, do: normalization_digest(commune_normalizer_digests())

  @doc false
  def normalization_digest(commune_digests) when is_map(commune_digests) do
    {__MODULE__.module_info(:md5), Enum.sort(Map.to_list(commune_digests))}
    |> :erlang.term_to_binary([:deterministic])
    |> BrusselsWtf.Digest.sha256()
  end

  defp commune_normalizer_digests do
    agenda = Map.new(@commune_normalizers, fn {slug, module} -> {slug, module_digest(module)} end)

    minutes =
      Map.new(@minutes_normalizers, fn {slug, module} ->
        {"#{slug}:minutes", module_digest(module)}
      end)

    Map.merge(agenda, minutes)
  end

  defp module_digest(module) do
    if loaded_normalizer?(module), do: module.module_info(:md5), else: :not_loaded
  end

  @impl true
  def normalize(input) when is_map(input) do
    case BrusselsWtf.Corpus.Manifest.normalize(input) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, :processor_unimplemented} -> commune_normalize(input)
      # A recorded contract that rejected its own bytes stays closed: the composite
      # reports an unavailable normalizer rather than a partial commune reading.
      {:error, _other} -> {:error, :processor_unimplemented}
    end
  end

  def normalize(_input), do: {:error, :processor_unimplemented}

  defp commune_normalize(input) do
    case commune_normalizer(input) do
      {:ok, module} -> module.normalize(input)
      :error -> {:error, :processor_unimplemented}
    end
  end

  defp commune_normalizer(%{"commune_slug" => slug, "role" => "minutes"}) when is_binary(slug) do
    case Map.fetch(@minutes_normalizers, slug) do
      {:ok, module} -> if loaded_normalizer?(module), do: {:ok, module}, else: :error
      :error -> commune_agenda_normalizer(slug)
    end
  end

  defp commune_normalizer(%{"commune_slug" => slug}) when is_binary(slug),
    do: commune_agenda_normalizer(slug)

  defp commune_normalizer(_input), do: :error

  defp commune_agenda_normalizer(slug) do
    case Map.fetch(@commune_normalizers, slug) do
      {:ok, module} -> if loaded_normalizer?(module), do: {:ok, module}, else: :error
      :error -> :error
    end
  end

  defp loaded_normalizer?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :normalize, 1)
  end
end
