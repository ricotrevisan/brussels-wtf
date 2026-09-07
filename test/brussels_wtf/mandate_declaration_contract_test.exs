defmodule BrusselsWtf.MandateDeclarationContractTest do
  use ExUnit.Case, async: true
  alias BrusselsWtf.Identity.MandateDeclaration

  @sha "c5b717d6243bd8ad3957f486ca9408a153c636927314642d03ec50e4505fbca2"
  @text File.read!("test/support/fixtures/ixelles/mandates/approved-2024.extract.txt")

  test "observed OCR layout matches the inspected production contract" do
    assert {:ok, document} = MandateDeclaration.parse(@sha, MandateDeclaration.origin(), @text)
    assert document.page == 14
    assert document.attestation_page == 17
    assert document.effective_from == ~D[2024-12-01]
    assert document.effective_to == ~D[2024-12-31]
    assert document.family_name == "CALOMNE"
    assert document.signed?

    assert {:ok, ^document} =
             MandateDeclaration.parse(
               @sha,
               MandateDeclaration.origin(),
               MandateDeclaration.safe_text(@sha, @text)
             )
  end

  test "new bytes cannot inherit the inspected signature contract" do
    assert {:error, :uninspected_source_version} =
             MandateDeclaration.parse(
               String.duplicate("0", 64),
               MandateDeclaration.origin(),
               @text
             )
  end

  test "duplicate native OCR layers and altered identities remain ambiguous" do
    duplicate = String.replace(@text, "Nam : CALOMNE", "Nom : CALOMNE\nNom : CALOMNE")
    assert {:error, _} = MandateDeclaration.parse(@sha, MandateDeclaration.origin(), duplicate)
    changed = String.replace(@text, "CALOMNE", "CALOMNESON")
    assert {:error, _} = MandateDeclaration.parse(@sha, MandateDeclaration.origin(), changed)
  end
end
