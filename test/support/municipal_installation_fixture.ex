defmodule BrusselsWtf.MunicipalInstallationFixture do
  @moduledoc false
  # Invented people and private sentinels; only the document shapes are source-derived.

  def pages(entries) do
    last = entries |> Map.keys() |> Enum.max()
    Enum.map_join(1..last, "\f", &Map.get(entries, &1, "")) <> "\f"
  end

  def pair("city-of-brussels") do
    installation =
      pages(%{
        1 => "CONSEIL COMMUNAL DE BRUXELLES\nSéance publique du dimanche 1er décembre 2024",
        8 => "Prêtent serment en français : Mme EXEMPLE, M. TEST.",
        22 =>
          "En conséquence, Mme Léa Exemple est proclamée première échevine. Elle\nprête serment en français et est installée dans ses fonctions d’échevine.\nPRIVATE TAIL: domicile 42 rue Interdite",
        25 =>
          "En conséquence, Mme Nora Autre est proclamée deuxième échevine. Elle prête\nserment en français et est installée dans ses fonctions d’échevine.",
        44 =>
          "En conséquence, M. Marc Incertain est proclamé septième (?)\néchevin. Il prête serment en français et est installé dans ses fonctions d’échevin.",
        57 =>
          "En conséquence, M. Louis Test est élu en qualité de Président du Conseil\ncommunal, et M. Hugo Remplaçant comme son suppléant pour la durée de la\nlégislature.",
        58 => """
        M. Louis Test prête le serment suivant :
        « Je jure fidélité au Roi, obeisance à la Constitution et aux lois du peuple
        belge. »
        M. Hugo Remplaçant prête le serment suivant :
        « Je jure fidélité au Roi, obeisance à la Constitution et aux lois du peuple
        belge. »
        PRIVATE TAIL: signature, secret@example.invalid
        """
      })

    corroboration =
      pages(%{
        1 => """
        CONSEIL COMMUNAL DE BRUXELLES
        Séance publique du lundi 20 avril 2026
        La séance publique est ouverte à 17h33 sous la présidence de M. Louis
        Test, Président.
        """,
        56 => "Le service de Nora Autre est cité. Mme EXEMPLE et M. TEST sont présents.",
        99 =>
          "Je remercie notre échevine de\nl’instruction publique, Mme Léa Exemple,\ndepuis vingt-cinq ans.\nPRIVATE TAIL: téléphone 010000000"
      })

    {installation, corroboration}
  end

  def pair("uccle") do
    installation =
      pages(%{
        1 => "COMMUNE D'UCCLE\nCONSEIL COMMUNAL DU 1 DÉCEMBRE 2024",
        3 => """
        01.12.2024/A/0004 Vérification complémentaire des pouvoirs, prestation de serment et installation
        des conseillers communaux.
        Les membres de l'Assemblée prêtent successivement, entre les mains de M. le
        Président, le serment prévu par l'article 80 de la nouvelle loi communale :
        - M. René Exemple prête serment en français ;
        Conseil communal - 01.12.2024 - Registre public
        3/31
        """,
        4 => """
        - Mme Anne Test-Lescot prête serment en français et en néerlandais ;
        M. le Président informe l'Assemblée du désistement.
        Mme Alice Remplaçant prête serment en français ;
        M. le Président en prend acte et la déclare installée comme Conseillère communale.
        Le Conseil prend connaissance.
        Bijkomend onderzoek van de geloofsbrieven
        PRIVATE TAIL: domicile 42 rue Interdite, secret@example.invalid
        """
      })

    corroboration =
      pages(%{
        1 => """
        COMMUNE D'UCCLE
        CONSEIL COMMUNAL DU 26 JUIN 2025
        Présents Anne Test-
        Aanwezig Lescot, Echevin(s)/Schepen(en) ;
        Camille Secrétaire, Le Secrétaire communal adjoint/De adjunct-gemeentesecretaris.
        Excusés Exemple René, Conseiller(s)
        Verontschuldigd communal(aux)/Gemeenteraadslid(leden).
        Ouverture de la séance à 18:30
        PRIVATE TAIL: téléphone 010000000
        """
      })

    {installation, corroboration}
  end

  def pair("forest") do
    installation =
      pages(%{
        1 => "ADMINISTRATION COMMUNALE DE FOREST\nCONSEIL COMMUNAL DU 1 DÉCEMBRE 2024",
        2 =>
          "C. Vérification des pouvoirs, prestation de serment et installation des membres du nouveau\nConseil communal.",
        3 => """
        Les élus prêtent successivement, entre les mains de M. le Bourgmestre-Président, le serment prévu à
        l'article 80 de la nouvelle loi communale :
        « Je jure fidélité au Roi, obéissance à la Constitution et aux lois du peuple belge. » OU
        « Ik zweer getrouwheid aan de Koning, gehoorzaamheid aan de Grondwet en aan de wetten van het
        Belgische volk. »
        Il est procédé l’appel suivant le tableau de préséance qu'il leur sera proposé d'adopter :
        M me Chloé EXEMPLE*, M. Jean-
        Louis TEST**, Mme Zoé AUTRE*.
        prêtent serment en français* / en néerlandais**.
        M. Le Bourgmestre - Président informe l'assemblée du désistement.
        M. Remplaçant Exclu prête serment en français.
        D. Fixation du tableau de préséance des membres du Conseil.
        PRIVATE TAIL: domicile 42 rue Interdite
        """
      })

    corroboration =
      pages(%{
        1 => """
        ADMINISTRATION COMMUNALE DE FOREST
        CONSEIL COMMUNAL DU 24 MARS 2026
        Présents Chloé Exemple, Présidente/Voorzitster ;
        Aanwezig Jean-Louis Test, Échevin(e)s/Schepenen ;
        Camille Secrétaire, Secrétaire communale/Gemeentesecretaris.
        Excusés Zoé Autre, Conseillers
        Verontschuldigd communaux/Gemeenteraadsleden.
        Ouverture de la séance à 19:42
        PRIVATE TAIL: secret@example.invalid
        """
      })

    {installation, corroboration}
  end

  def pair("ixelles") do
    installation =
      pages(%{
        1 => """
        COMMUNE D'IXELLES
        CONSEIL COMMUNAL DU 1 DÉCEMBRE 2024
        01.12.2024/A/0001 Vérification des pouvoirs, prestation de serment et installation des Conseillers
        communaux élus le 13 octobre 2024.
        """,
        4 => """
        Considérant qu’à l’appel de leur nom, les élus suivants ont prononcé le serment
        d’usage: RIVIÈRE Élodie, VAN TESTEN Luc ;
        Considérant que le Bourgmestre donne acte de leur prestation serment aux élus et
        déclare le Conseil légalement constitué ;
        PREND ACTE
        de la vérification des pouvoirs, de la prestation de serment et de l’installation des
        membres du Conseil communal élus le 13 octobre 2024.
        La présente délibération
        PRIVATE TAIL: domicile 42 rue Interdite; secret@example.invalid; née le 01/01/1970
        """,
        8 => """
        Considérant qu’à l’appel de leur nom, les suppléants suivants ont prononcé le serment
        d’usage: REMPLAÇANT Alice, MALFORMÉ, Jean ;
        """
      })

    corroboration =
      pages(%{
        1 => """
        COMMUNE D'IXELLES
        CONSEIL COMMUNAL DU 11 JUIN 2026
        Présents Élodie Rivière, Échevin(e)s/Schepenen ;
        Aanwezig Luc Van Testen, Conseillers(ères) communaux(ales)/Gemeenteraadsleden ;
        Camille Secrétaire, Secrétaire communale/Gemeentesecretaris.
        Excusés Alice Remplaçant,
        Verontschuldigd Conseillers(ères) communaux(ales)/Gemeenteraadsleden.
        Ouverture de la séance à 19:15
        PRIVATE TAIL: téléphone 010000000, secret@example.invalid
        """
      })

    {installation, corroboration}
  end
end
