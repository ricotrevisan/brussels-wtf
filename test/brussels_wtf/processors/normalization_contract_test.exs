defmodule BrusselsWtf.Processors.NormalizationContractTest do
  use ExUnit.Case, async: false

  alias BrusselsWtf.Corpus.Manifest
  alias BrusselsWtf.Processors
  alias BrusselsWtf.Processors.Council
  alias BrusselsWtf.Processors.IxellesCouncil
  alias BrusselsWtf.Processors.RecordedCorpus

  defmodule UndigestedProcessor do
    @moduledoc false
    @behaviour BrusselsWtf.Processors

    @impl true
    def extract(_meta, _bytes), do: {:error, :processor_unimplemented}

    @impl true
    def normalize(_extracted), do: {:error, :processor_unimplemented}
  end

  defmodule CommuneDigestProbeProcessor do
    @moduledoc false
    @behaviour BrusselsWtf.Processors

    @key {__MODULE__, :commune_digests}

    def put_commune_digests(digests), do: :persistent_term.put(@key, digests)
    def clear_commune_digests, do: :persistent_term.erase(@key)

    @impl true
    def extract(_meta, _bytes), do: {:error, :processor_unimplemented}

    @impl true
    def normalize(_extracted), do: {:error, :processor_unimplemented}

    @impl true
    def normalization_digest do
      Council.normalization_digest(:persistent_term.get(@key))
    end
  end

  setup do
    previous = Application.fetch_env!(:brussels_wtf, :processors)

    on_exit(fn ->
      Application.put_env(:brussels_wtf, :processors, previous)
      CommuneDigestProbeProcessor.clear_commune_digests()
    end)

    :ok
  end

  test "a processor without normalization_digest keeps the exact recorded contract shape" do
    Application.put_env(:brussels_wtf, :processors, UndigestedProcessor)
    assert Processors.normalization_contract() == recorded_shape(UndigestedProcessor)

    Application.put_env(:brussels_wtf, :processors, RecordedCorpus)
    assert Processors.normalization_contract() == recorded_shape(RecordedCorpus)
  end

  test "a changed commune-normalizer digest changes the contract" do
    Application.put_env(:brussels_wtf, :processors, CommuneDigestProbeProcessor)

    CommuneDigestProbeProcessor.put_commune_digests(%{"ixelles" => "md5-of-commune-code-a"})
    first = Processors.normalization_contract()

    CommuneDigestProbeProcessor.put_commune_digests(%{"ixelles" => "md5-of-commune-code-b"})
    second = Processors.normalization_contract()

    refute first == second
  end

  test "the configured composite contract is stable across repeated calls in one release" do
    Application.put_env(:brussels_wtf, :processors, Council)

    contracts = for _ <- 1..3, do: Processors.normalization_contract()

    assert length(Enum.uniq(contracts)) == 1
    assert Council.normalization_digest() == Council.normalization_digest()
  end

  test "the composite digest covers its own code and every configured commune normalizer" do
    expected =
      {Council.module_info(:md5), [{"ixelles", commune_normalizer_md5()}]}
      |> :erlang.term_to_binary([:deterministic])
      |> BrusselsWtf.Digest.sha256()

    assert Council.normalization_digest() == expected
    refute Council.normalization_digest() == Council.normalization_digest(%{})
  end

  test "an absent commune normalizer still yields a deterministic digest" do
    absent = Council.normalization_digest(%{"ixelles" => :not_loaded})

    assert absent == Council.normalization_digest(%{"ixelles" => :not_loaded})
    assert is_binary(absent)
    assert byte_size(absent) == 64
  end

  defp recorded_shape(processor) do
    {processor, processor.module_info(:md5), Manifest.module_info(:md5), Manifest.digest(),
     Manifest.digest("current-20260911")}
    |> :erlang.term_to_binary([:deterministic])
    |> BrusselsWtf.Digest.sha256()
  end

  defp commune_normalizer_md5 do
    if Code.ensure_loaded?(IxellesCouncil) and function_exported?(IxellesCouncil, :normalize, 1),
      do: IxellesCouncil.module_info(:md5),
      else: :not_loaded
  end
end
