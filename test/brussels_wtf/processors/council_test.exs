defmodule BrusselsWtf.Processors.CouncilTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Corpus.Manifest
  alias BrusselsWtf.Processors.Council
  alias BrusselsWtf.Processors.IxellesCouncil

  @unseen_sha256 String.duplicate("0", 64)

  setup_all do
    meeting = Manifest.meeting!("ixelles-267")
    source = hd(meeting["sources"])
    {text, 0} = System.cmd("pdftotext", ["-layout", Manifest.bundle_path!(source), "-"])

    %{source: source, text: text}
  end

  test "returns the recorded manifest result byte-identically for a hash-pinned source", %{
    source: source,
    text: text
  } do
    input = %{"sha256" => source["sha256"], "text" => text}

    assert {:ok, from_manifest} = Manifest.normalize(input)
    assert Council.normalize(input) == {:ok, from_manifest}
  end

  test "extra discovery context does not move a recorded hash to the commune branch", %{
    source: source,
    text: text
  } do
    contextual =
      Map.merge(%{"sha256" => source["sha256"], "text" => text}, %{
        "commune_slug" => "ixelles",
        "origin_url" => source["url"],
        "role" => "agenda",
        "language" => "fr",
        "meeting_identifier" => "267",
        "scheduled_on" => "2026-06-18",
        "item_identifier" => "1",
        "dossier_identifier" => nil
      })

    assert {:ok, from_manifest} = Manifest.normalize(contextual)
    assert Council.normalize(contextual) == {:ok, from_manifest}

    # The recorded contract short-circuits on the hash, so the commune context cannot
    # change the pinned result. Delegation would not reproduce this map.
    assert Council.normalize(contextual) == Manifest.normalize(contextual)
  end

  test "an unseen hash delegates only to a loaded commune normalizer" do
    input = %{
      "sha256" => @unseen_sha256,
      "text" => "unseen extracted text",
      "commune_slug" => "ixelles"
    }

    expected =
      if commune_normalizer_loaded?(),
        do: apply(IxellesCouncil, :normalize, [input]),
        else: {:error, :processor_unimplemented}

    assert Council.normalize(input) == expected
  end

  test "an unknown commune or missing discovery context fails closed" do
    assert Council.normalize(%{
             "sha256" => @unseen_sha256,
             "text" => "unseen extracted text",
             "commune_slug" => "uccle"
           }) == {:error, :processor_unimplemented}

    assert Council.normalize(%{"sha256" => @unseen_sha256, "text" => "unseen extracted text"}) ==
             {:error, :processor_unimplemented}

    assert Council.normalize(nil) == {:error, :processor_unimplemented}
  end

  test "a recorded hash whose markers do not match does not reach the commune branch", %{
    source: source
  } do
    assert {:error, {:normalization_ambiguity, _details}} =
             Manifest.normalize(%{"sha256" => source["sha256"], "text" => "unexpected text"})

    assert Council.normalize(%{
             "sha256" => source["sha256"],
             "text" => "unexpected text",
             "commune_slug" => "ixelles"
           }) == {:error, :processor_unimplemented}
  end

  test "extraction stays unimplemented in the processor behaviour" do
    assert Council.extract(%{sha256: @unseen_sha256}, "bytes") ==
             {:error, :processor_unimplemented}
  end

  defp commune_normalizer_loaded? do
    Code.ensure_loaded?(IxellesCouncil) and function_exported?(IxellesCouncil, :normalize, 1)
  end
end
