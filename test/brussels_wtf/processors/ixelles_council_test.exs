defmodule BrusselsWtf.Processors.IxellesCouncilTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Processors.IxellesCouncil

  # Real extracted text from the archived official Ixelles meeting 268 document
  # (priv/corpus/issue-33/sources/ixelles-268--primary.pdf), pages 1-2. The
  # document is the public complementary agenda for 2 July 2026.
  @agenda_page_one """
                                                                                               COMMUNE D'IXELLES
                                                                                                GEMEENTE ELSENE




      Veuillez noter qu'il y a lieu d'ajouter les points suivants à l'ordre du jour du Conseil communal
      du 2 juillet 2026, à 18:30.
      Gelieve volgende punten toe te voegen aan de agenda van de Gemeenteraad

      van 2 juli 2026, om 18:30.



      Veuillez agréer, Madame, Monsieur, l'assurance de notre considération distinguée.
      Met de meeste hoogachting.

                                                                                                  Ixelles, le 1 juillet 2026
                                                                                                       Elsene, 1 juli 2026

                                                                   Par ordonnance
                                                                     In opdracht
                       La Secrétaire communale,                                       La Présidente,
                        De gemeentesecretaris,                                        De voorzitster,




                           Patricia van der Lijn                                    Viviane Teitelbaum

                                                CONSEIL COMMUNAL DU 2 JUILLET 2026
                                                  GEMEENTERAAD VAN 2 JULI 2026


                                                     ORDRE DU JOUR COMPLÉMENTAIRE
                                                         AANVULLENDE AGENDA

                                                  SÉANCE PUBLIQUE - OPENBARE ZITTING


      Affaires générales - Algemene zaken

      1       Interpellation citoyenne introduite de la part de l'ensemble des Associations de Parents des écoles
              communales ixelloises, relative aux mesures prises dans les écoles communales pour faire face aux
              canicules. Porte-parole: Mme Muriel COURTOIS. (Complémentaire)

              Burgerinterpellatie, ingediend door alle oudersverenigingen van de gemeentescholen in Elsene,
              betreffende de maatregelen die in de gemeentescholen zijn genomen om hittegolven aan te pakken.
              Woordvoerster: mevr. Muriel COURTOIS. (Aanvullend)


      2       Procès-verbal de la séance du Conseil communal du 11 juin 2026. Approbation.

              Proces-verbaal van de gemeenteraadszitting van 11 juni 2026. Goedkeuring.




  Conseil communal - 02.07.2026 - Ordre du jour complémentaire public
  Gemeenteraad - 02.07.2026 - Aanvullende openbare agenda                                                                      1/25
  """

  @agenda_page_two """
      3       Information au Conseil communal des décisions prises par le Collège des Bourgmestre et Échevins,
              en application des articles 234 §3 et 234bis de la Nouvelle Loi Communale (26 mai 2026 ; 2 et 9 juin
              2026).

              Kennisgeving aan de gemeenteraad van de beslissingen van het college van burgemeester en
              schepenen, met toepassing van artikel 234, § 3, en artikel 234bis van de nieuwe gemeentewet (26 mei
              2026; 2 en 9 juni 2026).


      Evénements - Evenementen

      4       Octroi d’une subvention de projet en numéraire d’un montant de 700,00 EUR et en non numéraire
              évaluée à un montant de 5.158,00 EUR, relative à l’organisation d’une projection en plein air du film
              « La venue de l’avenir » dans le cadre de l’événement « Bruxelles fait son cinéma » le dimanche 5
              juillet 2026 dans les jardins de l’Abbaye de la Cambre. Bénéficiaire : asbl Libération Films
              Animation. Conventions. Approbation.

              Toekenning van een projectsubsidie in specie t.b.v. 700,00 EUR en in niet-specie, geraamd op een
              bedrag van 5.158,00 EUR, voor de organisatie van een openluchtvertoning van de film ‘La venue de
              l’avenir’ in het kader van het evenement ‘Bruxelles fait son cinéma’ op zondag 5 juli 2026 in de
              tuinen van de Abdij Ter Kameren. Begunstigde: vzw Libération Films Animation. Overeenkomsten.
              Goedkeuring.


      5       Octroi d'une subvention de projet en numéraire d'un montant de 1.250,00 EUR et en non numéraire
              évaluée à un montant de 2.376,00 EUR relative à l’organisation de l’événement « Back to the Roots
              Pride - Street Party » le samedi 16 mai 2026, rue du Prince Royal. Bénéficiaire : asbl Crazy Circle.
              Prise d’acte.

              Toekenning van een projectsubsidie in specie t.b.v. 1.250,00 EUR en in niet-specie, geraamd op een
              bedrag van 2.376,00 EUR, voor de organisatie van het evenement « Back to the Roots Pride - Street
              Party » op zaterdag 16 mei 2026 in de Koninklijke-Prinsstraat. Begunstigde: vzw Crazy Circle.
              Akteneming.


      6       Octroi d'une subvention de projet en numéraire d'un montant de 3.500,00 EUR relative à
              l’organisation du festival Matrimiel du 8 au 10 mai 2026, à l’Abbaye de la Cambre (1000 Bruxelles),
              la Fondation blan et la SAFFCA. Bénéficiaire : fup Fondation blan. Prise d’acte.

              Toekenning van een projectsubsidie in specie t.b.v. 3.500,00 EUR, voor de organisatie van het
              Matrimiel-festival van 8 tot en met 10 mei 2026 in de Abdij van Terkameren (1000 Brussel),
              Fondation blan en SAFFCA. Begunstigde: son Fondation blan. Akteneming.


      7       Octroi d'une subvention de projet en numéraire d'un montant de 7.500,00 EUR et en non numéraire
              évaluée à un montant de 1.455,80 EUR, relative à l’organisation du Festival Nayad sur les places
              Sainte-Croix, Eugène Flagey et Fernand Cocq du 3 au 5 juillet 2026 ainsi que dans le préau et la cour
              de l’Ecole n°5 (Etangs) les 4 et 5 juillet 2026. Bénéficiaire : asbl Merci Bonsoir. Conventions &
              Règlement d'ordre intérieur. Approbation.

              Toekenning van een projectsubsidie in specie t.b.v. 7.500,00 EUR en in niet-specie, geraamd op een
              bedrag van 1.455,80 EUR, voor de organisatie van het Festival Nayad van 3 tot 5 juli 2026, op de
              pleinen Heilig-Kruis, Eugène Flagey en Fernand Cocq alsook op de binnen- en de speelplaats van
              school nr. 5 (Vijvers) op 4 en 5 juli 2026. Begunstigde: vzw Merci Bonsoir. Overeenkomsten &
              Huishoudelijk reglement. Goedkeuring.


  Conseil communal - 02.07.2026 - Ordre du jour complémentaire public
  Gemeenteraad - 02.07.2026 - Aanvullende openbare agenda                                                             2/25
  """

  @agenda_text @agenda_page_one <> "\f" <> @agenda_page_two

  @expected_items [
    {"1",
     "Interpellation citoyenne introduite de la part de l'ensemble des Associations de Parents des écoles communales ixelloises, relative aux mesures prises dans les écoles communales pour faire face aux canicules. Porte-parole: Mme Muriel COURTOIS. (Complémentaire)",
     nil},
    {"2", "Procès-verbal de la séance du Conseil communal du 11 juin 2026. Approbation.",
     "Ordre du jour complémentaire, point 2, page 1/25"},
    {"3",
     "Information au Conseil communal des décisions prises par le Collège des Bourgmestre et Échevins, en application des articles 234 §3 et 234bis de la Nouvelle Loi Communale (26 mai 2026 ; 2 et 9 juin 2026).",
     nil},
    {"4",
     "Octroi d’une subvention de projet en numéraire d’un montant de 700,00 EUR et en non numéraire évaluée à un montant de 5.158,00 EUR, relative à l’organisation d’une projection en plein air du film « La venue de l’avenir » dans le cadre de l’événement « Bruxelles fait son cinéma » le dimanche 5 juillet 2026 dans les jardins de l’Abbaye de la Cambre. Bénéficiaire : asbl Libération Films Animation. Conventions. Approbation.",
     "Ordre du jour complémentaire, point 4, page 2/25"},
    {"5",
     "Octroi d'une subvention de projet en numéraire d'un montant de 1.250,00 EUR et en non numéraire évaluée à un montant de 2.376,00 EUR relative à l’organisation de l’événement « Back to the Roots Pride - Street Party » le samedi 16 mai 2026, rue du Prince Royal. Bénéficiaire : asbl Crazy Circle. Prise d’acte.",
     "Ordre du jour complémentaire, point 5, page 2/25"},
    {"6",
     "Octroi d'une subvention de projet en numéraire d'un montant de 3.500,00 EUR relative à l’organisation du festival Matrimiel du 8 au 10 mai 2026, à l’Abbaye de la Cambre (1000 Bruxelles), la Fondation blan et la SAFFCA. Bénéficiaire : fup Fondation blan. Prise d’acte.",
     "Ordre du jour complémentaire, point 6, page 2/25"},
    {"7",
     "Octroi d'une subvention de projet en numéraire d'un montant de 7.500,00 EUR et en non numéraire évaluée à un montant de 1.455,80 EUR, relative à l’organisation du Festival Nayad sur les places Sainte-Croix, Eugène Flagey et Fernand Cocq du 3 au 5 juillet 2026 ainsi que dans le préau et la cour de l’Ecole n°5 (Etangs) les 4 et 5 juillet 2026. Bénéficiaire : asbl Merci Bonsoir. Conventions & Règlement d'ordre intérieur. Approbation.",
     "Ordre du jour complémentaire, point 7, page 2/25"}
  ]

  # Real extracted text from the archived Ixelles meeting 267 minutes fixture
  # (test/support/fixtures/ixelles/final-267/sources/267-minutes.extract.txt).
  @minutes_text """
  COMMUNE D'IXELLES / GEMEENTE ELSENE
  CONSEIL COMMUNAL DU 11 JUIN 2026
  PROCÈS VERBAL / PROCES-VERBAAL
  11.06.2026/A/0002
  Procès-verbal de la séance du Conseil communal du 21 mai 2026. Approbation.
  Le Conseil approuve.
  37 votants : 37 votes positifs.
  De Raad keurt goed. 37 stemmers : 37 positieve stemmen.
  1/271
  """

  defp input(overrides \\ %{}) do
    base = %{
      "commune_slug" => "ixelles",
      "origin_url" => "https://www.ixelles.be/uploads/conseil/odj/268.pdf",
      "role" => "agenda",
      "language" => "bilingual",
      "meeting_identifier" => "268",
      "scheduled_on" => "2026-07-02",
      "item_identifier" => nil,
      "dossier_identifier" => nil,
      "sha256" => "f412ee4ddc45b454691fff79b190e36de0ae60fe6b696ae7861c82557b38fd4b",
      "page_count" => 25,
      "quality_accepted" => true
    }

    overrides
    |> Map.put_new("text", @agenda_text)
    |> then(&Map.merge(base, &1))
  end

  test "normalizes the real Ixelles agenda slice into verified proposals" do
    assert {:ok, normalized} = IxellesCouncil.normalize(input())

    assert normalized["meeting_identifier"] == "268"
    assert normalized["scheduled_on"] == "2026-07-02"
    assert normalized["agenda"] == %{"kind" => "complementary", "language" => "bilingual"}

    items = normalized["items"]

    # Regression contract: the exact real wordings and reported page locations.
    # The content-safety guard must not change any previously emitted item.
    assert Enum.map(items, &{&1["item_number"], &1["source_wording"], evidence_location(&1)}) ==
             @expected_items

    assert Enum.all?(items, &(not Map.has_key?(&1, "decisions")))
    assert Enum.all?(items, &(&1["source_wording"] != ""))

    information = Enum.find(items, &(&1["item_number"] == "3"))
    refute Map.has_key?(information, "proposals")

    proposal = Enum.find(items, &(&1["item_number"] == "4"))
    assert [%{"text" => text, "evidence" => evidence}] = proposal["proposals"]
    assert text == proposal["source_wording"]
    assert evidence["claim"] == "proposal"
    assert evidence["excerpt"] == text
    assert evidence["applicable_from"] == "2026-07-02"
    assert IxellesCouncil.verify_excerpt(evidence["excerpt"], @agenda_page_two) == :ok

    # Every emitted proposal excerpt must occur in the page text the item cites.
    for item <- items, proposals = Map.get(item, "proposals"), proposals != nil do
      for %{"evidence" => %{"excerpt" => excerpt}} <- proposals do
        assert IxellesCouncil.verify_excerpt(excerpt, @agenda_text) == :ok
      end
    end
  end

  test "fails closed when the French segment holds Dutch lines" do
    # The split point places the Dutch translation in the French slot. The old
    # code emitted it and passed excerpt verification because the excerpt was the
    # same string. The guard must reject the item instead.
    text = mis_split_document(nl_line(), nl_line())

    assert {:error, {:normalization_ambiguity, details}} =
             IxellesCouncil.normalize(input(%{"text" => text}))

    assert details["contract"] == "ixelles-council"
    assert [unverified] = details["unverified"]
    assert unverified["reason"] == "agenda_item_french_segment_is_dutch_dominant"
    assert unverified["marker_balance"] < 0
  end

  test "fails closed on an unmarked French segment that cannot be shown French-dominant" do
    text = mis_split_document("Zzz qqq vvv www xxx yyy.", nl_line())

    assert {:error, {:normalization_ambiguity, details}} =
             IxellesCouncil.normalize(input(%{"text" => text}))

    assert [unverified] = details["unverified"]
    assert unverified["reason"] == "agenda_item_french_segment_not_french_dominant"
    assert unverified["marker_balance"] == 0
  end

  test "fails closed on a French-only document with no Dutch translation" do
    text = mis_split_document(fr_line(), fr_line())

    assert {:error, {:normalization_ambiguity, details}} =
             IxellesCouncil.normalize(input(%{"text" => text}))

    assert details["contract"] == "ixelles-council"
    assert [unverified] = details["unverified"]
    assert unverified["reason"] == "agenda_item_has_no_dutch_translation"
  end

  defp evidence_location(item) do
    case Map.get(item, "proposals") do
      [%{"evidence" => %{"location" => location}}] -> location
      _other -> nil
    end
  end

  # A structurally valid Ixelles agenda whose single item body is built from the
  # supplied lines. `mis_split_document/2` keeps all identity markers so the guard,
  # not the identity check, is what rejects the item.
  defp mis_split_document(first_line, second_line) do
    """
        COMMUNE D'IXELLES
        GEMEENTE ELSENE
        CONSEIL COMMUNAL DU 2 JUILLET 2026
        GEMEENTERAAD VAN 2 JULI 2026
        ORDRE DU JOUR COMPLÉMENTAIRE
        AANVULLENDE AGENDA

        1       #{first_line}

                #{second_line}

    Conseil communal - 02.07.2026 - Ordre du jour complémentaire public
    """
  end

  defp nl_line do
    "Toekenning van een projectsubsidie voor werken, levering en plaatsing."
  end

  defp fr_line do
    "Approbation de la convention et du règlement communal relatif aux travaux."
  end

  test "fails closed when the dated meeting heading does not match the context" do
    assert {:error, {:normalization_ambiguity, details}} =
             IxellesCouncil.normalize(input(%{"scheduled_on" => "2026-07-09"}))

    assert details["contract"] == "ixelles-council"
    assert "meeting_heading" in details["missing_markers"]
    assert "meeting_date_footer" in details["missing_markers"]
  end

  test "fails closed when the commune header is absent from the text" do
    stripped = String.replace(@agenda_text, "COMMUNE D'IXELLES", "COMMUNE")

    assert {:error, {:normalization_ambiguity, details}} =
             IxellesCouncil.normalize(input(%{"text" => stripped}))

    assert "commune_fr" in details["missing_markers"]
  end

  test "leaves non-Ixelles communes unsupported" do
    assert {:error, :processor_unimplemented} =
             IxellesCouncil.normalize(input(%{"commune_slug" => "forest"}))

    assert {:error, :processor_unimplemented} =
             IxellesCouncil.normalize(
               input(%{"commune_slug" => "uccle", "scheduled_on" => "2026-09-10"})
             )
  end

  test "leaves a minutes-style document unsupported" do
    minutes = %{
      "text" => @minutes_text,
      "role" => "minutes",
      "meeting_identifier" => "267",
      "scheduled_on" => "2026-06-11"
    }

    assert {:error, :processor_unimplemented} = IxellesCouncil.normalize(input(minutes))

    assert {:error, :processor_unimplemented} =
             IxellesCouncil.normalize(input(Map.put(minutes, "role", nil)))
  end

  test "requires meeting identity from the acquisition context" do
    assert {:error, :processor_unimplemented} =
             IxellesCouncil.normalize(input(%{"meeting_identifier" => nil}))

    assert {:error, :processor_unimplemented} =
             IxellesCouncil.normalize(input(%{"scheduled_on" => nil}))

    assert {:error, :processor_unimplemented} =
             IxellesCouncil.normalize(input(%{"meeting_identifier" => "   "}))
  end

  test "leaves a non-agenda role unsupported" do
    assert {:error, :processor_unimplemented} =
             IxellesCouncil.normalize(input(%{"role" => "explanatory_note"}))

    assert {:error, :processor_unimplemented} =
             IxellesCouncil.normalize(input(%{"role" => "project"}))
  end

  test "rejects fabricated evidence excerpts" do
    real = "Octroi d’une subvention de projet en numéraire d’un montant de 700,00 EUR"

    assert IxellesCouncil.verify_excerpt(real, @agenda_page_two) == :ok

    assert {:error, :excerpt_not_found} =
             IxellesCouncil.verify_excerpt(
               "Subvention inventée pour un événement qui n’existe pas.",
               @agenda_page_two
             )

    assert {:error, :excerpt_not_found} =
             IxellesCouncil.verify_excerpt(real, @agenda_page_one)
  end
end
