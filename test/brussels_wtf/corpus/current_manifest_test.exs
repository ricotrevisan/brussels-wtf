defmodule BrusselsWtf.Corpus.CurrentManifestTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Corpus.Manifest

  @ixelles_sha "eefafbaf225c2d00e501e1d826ddcde084bef7dfbf3c9b2a034803da39a11670"
  @ixelles_url "https://www.ixelles.be/uploads/conseil/odj/269.pdf"

  # Minimal native Poppler extracts from the official 2026-09-17 agenda,
  # captured 2026-09-11. Keep the original page positions. Raw PDFs stay private.
  @ixelles_page_seven """
  38 Enseignement pour adultes – Institut Fernand Cocq: Approbation de la convention entre la Commune d’Ixelles et l’Institut Royal pour Sourds et Aveugles relative à l’organisation d’ateliers de conversation en langue des signes (niveau intermédiaire) durant l’année scolaire 2026-2027.

  39 Marché public de fournitures n°2023-1011 à passer en recourant aux services de la centrale d’achat CREAT. Acquisition de mobilier scolaire. Code CPV : 39160000-1 « mobilier scolaire ». Marché à bordereau de prix. Article 234 §1 de la NLC. Conditions du marché de la centrale d’achat CREAT (réf CREAT : Schoolmeubilair – octobre 2023). Inscriptions budgétaires pour les exercices budgétaires 2026, 2027 et 2028. Dépense supplémentaire : 143.000,00 EUR TVAC (taux TVA : 21 %), révision des prix et révision des quantités présumées comprises. Approbation.
  """

  test "current selected proposals normalize from real page excerpts and produce three recorded locales" do
    assert %{"meetings" => meetings} = Manifest.load!("current-20260911")
    assert length(meetings) == 4

    text =
      "CONSEIL COMMUNAL DU 17 SEPTEMBRE 2026" <> String.duplicate("\f", 6) <> @ixelles_page_seven

    assert {:ok, normalized} = Manifest.normalize(%{"sha256" => @ixelles_sha, "text" => text})
    assert normalized["meeting_identifier"] == "269"
    assert Enum.map(normalized["items"], & &1["item_number"]) == ["38", "39"]
    assert Enum.all?(normalized["items"], &(not Map.has_key?(&1, "decisions")))

    input = publication_input(normalized, "ixelles", @ixelles_sha, @ixelles_url)
    assert {:ok, canonical} = Manifest.recorded_bundle(input, "fr")
    assert canonical["page"]["summary"] =~ "deux propositions"
    assert canonical["items"]["39"]["variant"]["summary"] =~ "143 000"

    assert canonical["items"]["39"]["variant"]["summary"] =~
             "pour l’acquisition de mobilier scolaire via CREAT"

    assert {:ok, nl} = Manifest.recorded_translation(canonical, "nl")
    assert nl["items"]["39"]["variant"]["summary"] =~ "143.000"
    assert {:ok, en} = Manifest.recorded_translation(canonical, "en")
    assert en["items"]["39"]["variant"]["summary"] =~ "€143,000"
    assert en["items"]["39"]["variant"]["summary"] =~ "furniture to be purchased through CREAT"

    changed = put_in(input, ["items", Access.at(0), "outcome"], "approved")
    assert {:error, :recorded_coverage_not_available} = Manifest.recorded_bundle(changed, "fr")

    wrong_pages =
      @ixelles_page_seven <> String.duplicate("\f", 6) <> "CONSEIL COMMUNAL DU 17 SEPTEMBRE 2026"

    assert {:error, {:normalization_ambiguity, _}} =
             Manifest.normalize(%{"sha256" => @ixelles_sha, "text" => wrong_pages})
  end

  test "current lookup preserves the sealed legacy default and adds only eight selected proposals" do
    legacy = Manifest.load!()
    current = Manifest.load!("current-20260911")

    assert Manifest.digest() == Manifest.digest("issue-33")
    refute Manifest.digest() == Manifest.digest("current-20260911")
    assert Manifest.load!("issue-33") == legacy
    assert length(legacy["meetings"]) == 8
    assert length(Manifest.all_meetings()) == 12
    assert_raise ArgumentError, fn -> Manifest.load!("../../config") end
    assert_raise ArgumentError, fn -> Manifest.digest("unknown") end

    assert Map.new(
             current["meetings"],
             &{&1["key"], Enum.map(&1["items"], fn item -> item["key"] end)}
           ) == %{
             "ixelles-269" => ["38", "39"],
             "forest-2026-09-01" => ["forest-2026-09-01-13", "forest-2026-09-01-45"],
             "uccle-2026-09-10" => ["12", "38"],
             "city-2026-09-07" => ["2722248", "2728690"]
           }

    for meeting <- current["meetings"] do
      assert [source] = meeting["sources"]
      assert source["acquisition"] == "official_fetch"
      refute Map.has_key?(source, "bundle_path")
      assert source["role"] in ~w(agenda complementary_explanatory_note)
      assert source["byte_size"] <= 2_000_000
      assert {^meeting, ^source} = Manifest.source_by_sha256(source["sha256"])
      assert Manifest.meeting!(meeting["key"]) == meeting

      assert Manifest.meeting_by_identity(meeting["commune"], meeting["municipal_identifier"]) ==
               meeting

      assert length(meeting["items"]) == 2

      assert Enum.all?(
               meeting["items"],
               &(&1["state"] == "proposal" and &1["outcome"] == "unknown")
             )
    end
  end

  test "current recorded translation rejects altered canonical French content and claim references" do
    text =
      "CONSEIL COMMUNAL DU 17 SEPTEMBRE 2026" <> String.duplicate("\f", 6) <> @ixelles_page_seven

    assert {:ok, normalized} = Manifest.normalize(%{"sha256" => @ixelles_sha, "text" => text})
    input = publication_input(normalized, "ixelles", @ixelles_sha, @ixelles_url)
    assert {:ok, canonical} = Manifest.recorded_bundle(input, "fr")

    changes = [
      {"page title", put_in(canonical, ["page", "title"], "Tous les points sont approuvés")},
      {"page summary", put_in(canonical, ["page", "summary"], "Tous les points sont approuvés")},
      {"item title", put_in(canonical, ["items", "39", "variant", "title"], "Mobilier approuvé")},
      {"item summary",
       put_in(canonical, ["items", "39", "variant", "summary"], "Le marché est attribué.")},
      {"proposal summary",
       put_in(
         canonical,
         ["items", "39", "variant", "proposal_summary"],
         "Le marché est attribué."
       )},
      {"decision summary",
       put_in(
         canonical,
         ["items", "39", "variant", "decision_summary"],
         "Le marché est attribué."
       )},
      {"page references", put_in(canonical, ["page", "claim_refs"], ["proposal:unsupported"])},
      {"item references",
       put_in(canonical, ["items", "39", "claim_refs"], ["proposal:unsupported"])},
      {"missing page references", put_in(canonical, ["page", "claim_refs"], [])},
      {"extra item references",
       update_in(canonical, ["items", "39", "claim_refs"], &["proposal:unsupported" | &1])},
      {"missing item", update_in(canonical, ["items"], &Map.delete(&1, "39"))},
      {"extra item", put_in(canonical, ["items", "40"], canonical["items"]["39"])}
    ]

    for {change, invalid} <- changes, locale <- ~w(nl en) do
      assert Manifest.recorded_translation(invalid, locale) ==
               {:error, :recorded_translation_not_available},
             "accepted altered #{change} for #{locale}"
    end
  end

  test "current coverage rejects unknown source bytes and changed publication facts or selections" do
    text =
      "CONSEIL COMMUNAL DU 17 SEPTEMBRE 2026" <> String.duplicate("\f", 6) <> @ixelles_page_seven

    assert {:error, :processor_unimplemented} =
             Manifest.normalize(%{"sha256" => String.duplicate("0", 64), "text" => text})

    assert {:ok, normalized} = Manifest.normalize(%{"sha256" => @ixelles_sha, "text" => text})
    input = publication_input(normalized, "ixelles", @ixelles_sha, @ixelles_url)
    assert {:ok, _} = Manifest.recorded_bundle(input, "fr")

    claim_path = ["items", Access.at(0), "claims", Access.at(0)]
    evidence_path = claim_path ++ ["evidence", Access.at(0)]
    [first, second] = input["items"]
    extra = %{first | "key" => "40", "item_number" => "40"}

    changes = [
      {"meeting date", put_in(input, ["scheduled_on"], "2026-09-18")},
      {"missing selected item", put_in(input, ["items"], [first])},
      {"extra selected item", put_in(input, ["items"], [first, second, extra])},
      {"duplicate selected item", put_in(input, ["items"], [first, first])},
      {"claim text", put_in(input, claim_path ++ ["text"], "Le marché est attribué.")},
      {"claim reference", put_in(input, claim_path ++ ["key"], "proposal:unsupported")},
      {"evidence excerpt", put_in(input, evidence_path ++ ["excerpt"], "Le Conseil approuve.")},
      {"evidence hash",
       put_in(input, evidence_path ++ ["source_sha256"], String.duplicate("0", 64))}
    ]

    for {change, invalid} <- changes do
      assert Manifest.recorded_bundle(invalid, "fr") ==
               {:error, :recorded_coverage_not_available},
             "accepted changed #{change}"
    end
  end

  defp publication_input(normalized, commune, sha, url) do
    %{
      "commune_slug" => commune,
      "meeting_identifier" => normalized["meeting_identifier"],
      "scheduled_on" => normalized["scheduled_on"],
      "items" =>
        Enum.map(normalized["items"], fn item ->
          [proposal] = item["proposals"]
          key = item["authoritative_identifier"]

          %{
            "key" => key,
            "item_number" => item["item_number"],
            "procedural_state" => "proposal",
            "outcome" => "unknown",
            "source_wording" => item["source_wording"],
            "claims" => [
              %{
                "key" => "proposal:#{key}:#{sha}",
                "kind" => "proposal",
                "text" => proposal["text"],
                "evidence" => [
                  %{
                    "citation_url" => url,
                    "source_origin_url" => url,
                    "source_sha256" => sha,
                    "excerpt" => proposal["evidence"]["excerpt"],
                    "location" => proposal["evidence"]["location"],
                    "synthetic" => false
                  }
                ]
              }
            ]
          }
        end)
    }
  end
end
