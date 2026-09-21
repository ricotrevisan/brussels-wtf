defmodule BrusselsWtf.MunicipalInstallationSourceTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Identity.MunicipalInstallation.Source
  alias BrusselsWtf.MunicipalInstallationFixture, as: Fixture

  test "Ixelles completed titular oath and independent roster preserve exact public spans" do
    {:ok, contract} = Source.contract("ixelles")
    {installation, corroboration} = Fixture.pair("ixelles")
    assert {:ok, [first, second]} = Source.installations(contract, installation)
    assert first.legal_name == "RIVIÈRE Élodie"
    assert second.legal_name == "VAN TESTEN Luc"
    assert first.role_key == "municipal_councillor"

    assert first.role_labels == %{
             fr: "Conseiller communal",
             nl: "Gemeenteraadslid",
             en: "Municipal councillor"
           }

    assert first.effective_from == ~D[2024-12-01]
    assert first.effective_to == nil
    assert first.page == 4
    assert first.evidence_location == "installation 2024-12-01 page 4"
    assert String.contains?(installation, first.evidence_excerpt)
    assert first.evidence_excerpt =~ "ont prononcé le serment"
    assert first.evidence_excerpt =~ "PREND ACTE"
    refute first.evidence_excerpt =~ "PRIVATE"

    assert {:ok, %{candidates: [one, two], excluded: []}} =
             Source.match_candidates(contract, installation, corroboration)

    assert one.legal_name == "Élodie Rivière"
    assert two.legal_name == "Luc Van Testen"
    assert one.identity_evidence.role_key == "alderman"
    assert one.identity_evidence.page == 1
    assert one.identity_evidence.legal_name == "Élodie Rivière"
    assert one.identity_evidence.evidence_excerpt == "Élodie Rivière, Échevin(e)s/Schepenen"
    assert {:ok, identities} = Source.corroborations(contract, corroboration)

    assert Enum.map(identities, & &1.legal_name) == [
             "Élodie Rivière",
             "Luc Van Testen",
             "Alice Remplaçant"
           ]

    assert one.effective_to == nil
    refute inspect([one, two]) =~ "PRIVATE"
    refute inspect([one, two]) =~ "Secrétaire"
  end

  test "Uccle cross-page completed titular oaths exclude replacement and secretary" do
    {:ok, contract} = Source.contract("uccle")
    {installation, corroboration} = Fixture.pair("uccle")
    assert {:ok, [first, second]} = Source.installations(contract, installation)

    assert {first.legal_name, first.page, second.legal_name, second.page} ==
             {"René Exemple", 3, "Anne Test-Lescot", 4}

    assert first.evidence_excerpt == "- M. René Exemple prête serment en français ;"

    assert {:ok, %{candidates: [one, two], excluded: []}} =
             Source.match_candidates(contract, installation, corroboration)

    assert [one.legal_name, two.legal_name] == ["Exemple René", "Anne Test-Lescot"]
    assert one.effective_from == ~D[2024-12-01]
    assert one.effective_to == nil
    assert one.identity_evidence.role_key == "municipal_councillor"
    assert String.contains?(corroboration, two.identity_evidence.evidence_excerpt)
    refute inspect([one, two]) =~ "PRIVATE"
    refute inspect([one, two]) =~ "Secrétaire"
  end

  test "Forest honours and wrapped hyphens preserve spellings and exact oath list context" do
    {:ok, contract} = Source.contract("forest")
    {installation, corroboration} = Fixture.pair("forest")
    assert {:ok, events} = Source.installations(contract, installation)

    assert Enum.map(events, &{&1.legal_name, &1.page}) == [
             {"Chloé EXEMPLE", 3},
             {"Jean-Louis TEST", 3},
             {"Zoé AUTRE", 3}
           ]

    assert {:ok, %{candidates: candidates, excluded: []}} =
             Source.match_candidates(contract, installation, corroboration)

    assert Enum.map(candidates, & &1.legal_name) == [
             "Chloé Exemple",
             "Jean-Louis Test",
             "Zoé Autre"
           ]

    for event <- candidates do
      assert event.effective_to == nil
      assert String.contains?(installation, event.evidence_excerpt)
      assert String.contains?(corroboration, event.identity_evidence.evidence_excerpt)
      refute event.evidence_excerpt =~ "PRIVATE"
      refute event.evidence_excerpt =~ "désistement"
    end
  end

  test "City full completed offices plus chair oath, not surname lists, deputy or uncertain rank" do
    {:ok, contract} = Source.contract("city-of-brussels")
    {installation, corroboration} = Fixture.pair("city-of-brussels")
    assert {:ok, events} = Source.installations(contract, installation)

    assert Enum.map(events, &{&1.legal_name, &1.role_key, &1.page}) == [
             {"Léa Exemple", "alderman", 22},
             {"Nora Autre", "alderman", 25},
             {"Louis Test", "council_chair", 57}
           ]

    assert {:ok, %{candidates: [alderman, chair], excluded: [surname, excluded, uncertain]}} =
             Source.match_candidates(contract, installation, corroboration)

    assert {alderman.legal_name, alderman.identity_evidence.page} == {"Léa Exemple", 99}
    assert {chair.legal_name, chair.identity_evidence.page} == {"Louis Test", 1}
    assert chair.oath_evidence.page == 58
    assert String.contains?(installation, chair.oath_evidence.evidence_excerpt)
    assert excluded == %{reason: :identity_not_corroborated, role_key: "alderman", page: 25}

    assert surname == %{
             reason: :surname_only_installation,
             role_key: "municipal_councillor",
             page: 8
           }

    assert uncertain == %{reason: :uncertain_rank, role_key: "alderman", page: 44}

    assert alderman.identity_evidence.evidence_excerpt ==
             "notre échevine de\nl’instruction publique, Mme Léa Exemple,"

    for event <- [alderman, chair] do
      assert event.effective_from == ~D[2024-12-01]
      assert event.effective_to == nil
      assert String.contains?(installation, event.evidence_excerpt)
      assert String.contains?(corroboration, event.identity_evidence.evidence_excerpt)
      refute inspect(event) =~ "PRIVATE"
    end
  end

  test "a unique independent identity can corroborate separate offices, but duplicate roster identities cannot" do
    {:ok, contract} = Source.contract("city-of-brussels")
    {installation, corroboration} = Fixture.pair(contract.slug)
    installation = String.replace(installation, "Nora Autre", "Louis Test")

    assert {:ok, %{candidates: candidates}} =
             Source.match_candidates(contract, installation, corroboration)

    assert Enum.map(candidates, &{&1.legal_name, &1.role_key}) == [
             {"Léa Exemple", "alderman"},
             {"Louis Test", "alderman"},
             {"Louis Test", "council_chair"}
           ]

    assert hd(candidates).role_labels == %{
             en: "Alderperson",
             fr: "Membre du collège communal",
             nl: "Schepen"
           }

    duplicate_roster = String.replace(corroboration, "Léa Exemple", "Louis Test")

    assert {:ok, %{candidates: [], excluded: excluded}} =
             Source.match_candidates(contract, installation, duplicate_roster)

    assert Enum.count(excluded, &(&1.reason == :ambiguous_identity)) == 2
  end

  test "document date and commune must be in the header and registry metadata is immutable" do
    for contract <- Source.contracts() do
      {installation, corroboration} = Fixture.pair(contract.slug)
      wrong_date = String.replace(installation, "2024", "2023")
      wrong_corroboration_date = String.replace(corroboration, ~r/202[56]/, "2022")
      assert {:error, :invalid_document_header} = Source.installations(contract, wrong_date)

      assert {:error, :invalid_document_header} =
               Source.corroborations(contract, wrong_corroboration_date)

      for field <- [:sha256, :url, :parent_index_url, :date] do
        altered = put_in(contract, [:installation, field], "unapproved")
        assert {:error, :unsupported_contract} = Source.installations(altered, installation)
      end

      assert {:error, :unsupported_contract} =
               Source.installations(%{contract | slug: "other"}, installation)

      assert {:error, :invalid_text} = Source.installations(contract, nil)
    end

    {:ok, contract} = Source.contract("ixelles")
    {installation, _} = Fixture.pair("ixelles")

    assert {:error, :invalid_document_header} =
             Source.installations(
               contract,
               String.replace(installation, "COMMUNE D'IXELLES", "COMMUNE D'UCCLE")
             )
  end

  test "changing completed markers or section envelopes fails closed" do
    changes = [
      {"ixelles", "déclare le Conseil légalement constitué",
       "ne déclare pas le Conseil légalement constitué"},
      {"ixelles", "PREND ACTE", "PROPOSE"},
      {"ixelles", "01.12.2024/A/0001", "01.12.2024/A/0099"},
      {"uccle", "Le Conseil prend connaissance.", "Le Conseil ne prend pas connaissance."},
      {"uccle", "01.12.2024/A/0004", "01.12.2024/A/0099"},
      {"forest", "prêtent serment en français* / en néerlandais**.", "ne prêtent pas serment."},
      {"forest", "C. Vérification", "Z. Vérification"},
      {"forest", "D. Fixation", "Z. Fixation"}
    ]

    for {slug, from, to} <- changes do
      {:ok, contract} = Source.contract(slug)
      {installation, _} = Fixture.pair(slug)

      assert {:error, :installation_section_invalid} =
               Source.installations(contract, String.replace(installation, from, to))
    end
  end

  test "proposed and negated oaths never become completed events" do
    for {slug, replacements} <- [
          {"ixelles",
           [
             {"ont prononcé le serment", "prononceront le serment"},
             {"ont prononcé le serment", "n’ont pas prononcé le serment"}
           ]},
          {"uccle",
           [{"prête serment", "prêtera serment"}, {"prête serment", "ne prête pas serment"}]},
          {"forest",
           [
             {"Les élus prêtent successivement", "Les élus prêteront successivement"},
             {"Les élus prêtent successivement", "Les élus ne prêtent pas successivement"}
           ]},
          {"city-of-brussels",
           [{"En conséquence,", "Il est proposé que"}, {"est proclamée", "n’est pas proclamée"}]}
        ] do
      {:ok, contract} = Source.contract(slug)
      {installation, _} = Fixture.pair(slug)

      for {from, to} <- replacements do
        # Remove the independent chair event to isolate alderman disposition.
        text =
          installation
          |> String.replace(
            "M. Louis Test prête le serment",
            "M. Louis Test ne prête pas le serment"
          )
          |> String.replace(from, to)

        assert {:error, :installation_section_invalid} = Source.installations(contract, text)
      end
    end
  end

  test "City chair requires a completed oath by that full name, not the deputy" do
    {:ok, contract} = Source.contract("city-of-brussels")
    {installation, _} = Fixture.pair(contract.slug)

    text =
      String.replace(
        installation,
        "M. Louis Test prête le serment suivant",
        "M. Autre Homme prête le serment suivant"
      )

    assert {:ok, events} = Source.installations(contract, text)
    assert Enum.map(events, & &1.role_key) == ["alderman", "alderman"]
  end

  test "names in later attendance, wrong pages and signature tails are not identity evidence" do
    for contract <- Source.contracts() do
      {installation, corroboration} = Fixture.pair(contract.slug)
      moved = "\f" <> corroboration
      assert {:error, :invalid_document_header} = Source.corroborations(contract, moved)
      [first | _] = String.split(corroboration, "\f")
      header = first |> String.split("\n") |> Enum.take(2) |> Enum.join("\n")
      text = header <> "\f" <> corroboration

      assert {:error, :corroboration_section_invalid} =
               Source.match_candidates(contract, installation, text)
    end
  end

  test "duplicate roster and installation identities remain ambiguous even with exact names" do
    {:ok, contract} = Source.contract("ixelles")
    {installation, corroboration} = Fixture.pair(contract.slug)

    duplicate_roster =
      String.replace(
        corroboration,
        "Élodie Rivière, Échevin",
        "Élodie Rivière, RIVIÈRE Élodie, Échevin"
      )

    assert {:ok, %{candidates: [only], excluded: [%{reason: :ambiguous_identity}]}} =
             Source.match_candidates(contract, installation, duplicate_roster)

    assert only.legal_name == "Luc Van Testen"

    duplicate_installation =
      String.replace(installation, "RIVIÈRE Élodie,", "RIVIÈRE Élodie, Élodie RIVIÈRE,")

    assert {:ok, %{candidates: [only], excluded: excluded}} =
             Source.match_candidates(contract, duplicate_installation, corroboration)

    assert only.legal_name == "Luc Van Testen"
    assert Enum.map(excluded, & &1.reason) == [:ambiguous_identity, :ambiguous_identity]
    refute inspect(excluded) =~ "Élodie"
  end

  test "identity normalization preserves accents, hyphens, apostrophes and every token" do
    {:ok, contract} = Source.contract("ixelles")
    {installation, corroboration} = Fixture.pair(contract.slug)

    for changed <- [
          "Elodie Rivière",
          "Élodie Riviere",
          "Élodie Anne Rivière",
          "Élodie-Rivière",
          "Rivière"
        ] do
      text = String.replace(corroboration, "Élodie Rivière", changed)

      assert {:ok, %{candidates: [only], excluded: [%{reason: :identity_not_corroborated}]}} =
               Source.match_candidates(contract, installation, text)

      assert only.legal_name == "Luc Van Testen"
    end

    decomposed =
      String.replace(
        corroboration,
        "Élodie Rivière",
        String.normalize("  ÉLODIE   RIVIÈRE  ", :nfd)
      )

    assert {:ok, %{candidates: candidates}} =
             Source.match_candidates(contract, installation, decomposed)

    assert length(candidates) == 2
  end

  test "later oath-like rows and separate roster groups cannot cross section boundaries" do
    {:ok, contract} = Source.contract("uccle")
    {installation, corroboration} = Fixture.pair(contract.slug)

    text =
      String.replace(
        installation,
        "Bijkomend onderzoek",
        "- Mme Later Person prête serment en français ;\nBijkomend onderzoek"
      )

    assert {:ok, events} = Source.installations(contract, text)
    assert Enum.map(events, & &1.legal_name) == ["René Exemple", "Anne Test-Lescot"]

    text =
      String.replace(
        corroboration,
        "Ouverture de la séance",
        "Ouverture de la séance\nLater Person, Conseiller(s) communal(aux)/Gemeenteraadslid(leden) ;"
      )

    assert {:ok, identities} = Source.corroborations(contract, text)
    assert Enum.map(identities, & &1.legal_name) == ["Anne Test-Lescot", "Exemple René"]
  end

  test "hyphen and apostrophe differences remain distinct identities" do
    {:ok, contract} = Source.contract("forest")
    {installation, corroboration} = Fixture.pair(contract.slug)
    without_hyphen = String.replace(corroboration, "Jean-Louis Test", "Jean Louis Test")

    assert {:ok, %{candidates: candidates, excluded: [%{reason: :identity_not_corroborated}]}} =
             Source.match_candidates(contract, installation, without_hyphen)

    assert Enum.map(candidates, & &1.legal_name) == ["Chloé Exemple", "Zoé Autre"]
    installation = String.replace(installation, "Chloé EXEMPLE", "Chloé d’EXEMPLE")
    corroboration = String.replace(corroboration, "Chloé Exemple", "Chloé d'Exemple")

    assert {:ok, %{candidates: candidates, excluded: [%{reason: :identity_not_corroborated}]}} =
             Source.match_candidates(contract, installation, corroboration)

    assert Enum.map(candidates, & &1.legal_name) == ["Jean-Louis Test", "Zoé Autre"]
  end

  test "complete-token permutations are not enabled for ordinary given-family profiles" do
    {:ok, contract} = Source.contract("forest")
    {installation, corroboration} = Fixture.pair(contract.slug)
    text = String.replace(corroboration, "Chloé Exemple", "Exemple Chloé")

    assert {:ok, %{candidates: candidates, excluded: [%{reason: :identity_not_corroborated}]}} =
             Source.match_candidates(contract, installation, text)

    assert Enum.map(candidates, & &1.legal_name) == ["Jean-Louis Test", "Zoé Autre"]
  end

  test "private fields inside name groups are not copied as names or evidence" do
    {:ok, contract} = Source.contract("ixelles")
    {installation, corroboration} = Fixture.pair(contract.slug)

    for private <- [
          "née le 01/01/1970",
          "domicile rue Privée",
          "secret@example.invalid",
          "(Parti secret)",
          "signature privée"
        ] do
      text = String.replace(corroboration, "Élodie Rivière,", "Élodie Rivière #{private},")

      assert {:ok, %{candidates: [only], excluded: [%{reason: :identity_not_corroborated}]}} =
               Source.match_candidates(contract, installation, text)

      assert only.legal_name == "Luc Van Testen"
      refute inspect(only) =~ private
      text = String.replace(installation, "RIVIÈRE Élodie,", "RIVIÈRE Élodie #{private},")
      assert {:error, :installation_section_invalid} = Source.installations(contract, text)
    end
  end

  test "v1 approves four immutable document pairs, never people" do
    assert Enum.map(Source.contracts(), & &1.slug) == [
             "ixelles",
             "uccle",
             "forest",
             "city-of-brussels"
           ]

    assert {:ok, contract} = Source.contract("ixelles")
    assert contract.policy_version == 1

    assert contract.role_labels == %{
             "municipal_councillor" => %{
               fr: "Conseiller communal",
               nl: "Gemeenteraadslid",
               en: "Municipal councillor"
             }
           }

    assert contract.installation.date == ~D[2024-12-01]
    assert contract.corroboration.date == ~D[2026-06-11]

    assert contract.installation.sha256 ==
             "57b4ca56118d46178cf9c80692c49c92d6ab62f0cef5580610e8fb816b7eac06"

    assert contract.corroboration.sha256 ==
             "4ac4ed359acbc2d6f245226657f8a43e533281d533b3f16e1a3701ec97db87e5"

    assert contract.installation.parent_index_url ==
             "https://www.ixelles.be/site/page.php?numpage=11&annee=2024"

    assert {:error, :unsupported_commune} = Source.contract("elsewhere")
  end
end
