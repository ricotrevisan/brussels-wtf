defmodule BrusselsWtf.ForestAgendaFixture do
  @moduledoc """
  Shortened excerpts of the official Forest agendas of 22 September and 13 October 2026,
  keeping only the layouts tests need. The full documents stay private archive evidence;
  `test/contracts/forest_agenda_real_test.exs` checks them.
  """

  @header """
                                                               ADMINISTRATION COMMUNALE DE FOREST
                                                                            GEMEENTEBESTUUR VORST

                                           CONSEIL COMMUNAL DU 22 SEPTEMBRE 2026
                                            GEMEENTERAAD VAN 22 SEPTEMBER 2026


                                                           ORDRE DU JOUR
                                                              AGENDA

                                                 SÉANCE PUBLIQUE - OPENBARE ZITTING


    AFFAIRES GÉNÉRALES - ALGEMENE ZAKEN
    Secrétariat des assemblées - Secretariaat van de bestuursorganen

  """

  @page_one """
      1        Assemblées - Mandats (Forest Centre Culturel) - Remplacement.

               Bestuursorganen - Mandaten (Forest Centre Culturel) - Vervanging.


      2        Revitalisation des quartiers – ABY– Convention Bruxelles Environnement relative au lot 2 –
               Commande de suivi environnemental des parcelles, de la rédaction d’un


  """

  @page_two """
               rapport d’évaluation finale de gestion des risques – Budget complémentaire – Prise pour information.

               Heropleving van de wijken – ABY – Overeenkomst Leefmilieu Brussel – Opdracht voor milieumonitoring
               van de percelen – Aanvullende begroting – Kennisneming.
               4 annexes / 4 bijlagen

      3        Marchés publics – MP-2026-T-023 – Extension du remplacement de la fibre optique – Information.


  """

  @page_three """
               Overheidsopdrachten – MP-2026-T-023 – Uitbreiding van de vervanging van de glasvezelkabel –
               Kennisgeving.


    TRAVAUX PUBLICS - OPENBARE WERKEN
    Marchés publics - Overheidsopdrachten

      4        Voirie – Centrale d'achat – Adhésion à la centrale d'achat de l'Intercommunale.

               Wegenissen – Aankoopcentrale – Toetreding tot aankoopcentrale van de intercommunale


  """

  @page_four """
               IGEMO.
               3 annexes / 3 bijlagen

      5        Interpellation relative à la communication du BRASS (à la demande d'un conseiller communal).

               Interpellatie over de communicatie van BRASS (op vraag van een gemeenteraadslid).


      6        Question orale relative au dépôt clandestin (à la demande d'un conseiller communal).

               Mondelinge vraag over sluikstort (op vraag van een gemeenteraadslid).

  """

  def header, do: @header

  def footer(page, total) do
    "Conseil communal - 22.09.2026 - Ordre du jour public\n" <>
      "Gemeenteraad - 22.09.2026 - Openbare agenda                                  #{page}/#{total}\n"
  end

  def pages do
    [
      @header <> @page_one <> footer(1, 4),
      @page_two <> footer(2, 4),
      @page_three <> footer(3, 4),
      @page_four <> footer(4, 4)
    ]
  end

  def text, do: Enum.join(pages(), "\f") <> "\f"
end
