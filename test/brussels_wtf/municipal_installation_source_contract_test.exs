defmodule BrusselsWtf.MunicipalInstallationSourceContractTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Identity.MunicipalInstallation.Source

  # Opt in with MUNICIPAL_INSTALLATION_PDF_DIR and --include external. The private
  # directory contains <slug>-installation.pdf and <slug>-corroboration.pdf.
  # No document bytes, names or excerpts are logged or committed by this test.
  @moduletag :external
  @moduletag skip: is_nil(System.get_env("MUNICIPAL_INSTALLATION_PDF_DIR"))

  test "the eight independently hash-checked native PDFs satisfy the audited v1 contract" do
    directory = System.fetch_env!("MUNICIPAL_INSTALLATION_PDF_DIR")

    expected = %{
      "ixelles" => {38, 30},
      "uccle" => {40, 39},
      "forest" => {36, 29},
      "city-of-brussels" => {8, 2}
    }

    for contract <- Source.contracts() do
      texts =
        Map.new([:installation, :corroboration], fn kind ->
          path = Path.join(directory, "#{contract.slug}-#{kind}.pdf")
          sha256 = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
          assert sha256 == Map.fetch!(contract, kind).sha256
          {text, status} = System.cmd("pdftotext", ["-layout", path, "-"])
          assert status == 0
          {kind, text}
        end)

      {:ok, events} = Source.installations(contract, texts.installation)
      {:ok, result} = Source.match_candidates(contract, texts.installation, texts.corroboration)
      {event_count, candidate_count} = Map.fetch!(expected, contract.slug)
      assert length(events) == event_count, "#{contract.slug}: installation count"
      assert length(result.candidates) == candidate_count, "#{contract.slug}: candidate count"

      for candidate <- result.candidates do
        assert candidate.effective_from == ~D[2024-12-01]
        assert candidate.effective_to == nil
        assert String.contains?(texts.installation, candidate.evidence_excerpt)
        assert String.contains?(texts.corroboration, candidate.identity_evidence.evidence_excerpt)
      end
    end
  end
end
