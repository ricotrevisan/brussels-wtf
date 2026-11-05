defmodule BrusselsWtfWeb.PublicDescription do
  @moduledoc """
  Localized meta descriptions.

  They are fixed templates over already public labels. They never summarize
  coverage, so a description can state no claim or outcome that lacks evidence.
  """

  @limit 160

  @fixed %{
    home: %{
      "fr" =>
        "Suivez les ordres du jour et les décisions documentées des conseils d’Ixelles, Uccle, Forest et de la Ville de Bruxelles, avec leurs sources officielles.",
      "nl" =>
        "Volg agenda’s en gedocumenteerde beslissingen van de gemeenteraden van Elsene, Ukkel, Vorst en de Stad Brussel, met hun officiële bronnen.",
      "en" =>
        "Follow council agendas and documented decisions in Ixelles, Uccle, Forest and the City of Brussels, with their official sources."
    },
    about: %{
      "fr" =>
        "Comment brussels.wtf produit, cite et corrige sa couverture des conseils communaux, et ce que la publication compte sur sa lecture.",
      "nl" =>
        "Hoe brussels.wtf zijn verslaggeving over gemeenteraden maakt, citeert en corrigeert, en wat de publicatie over het lezen ervan telt.",
      "en" =>
        "How brussels.wtf produces, cites and corrects its coverage of municipal councils, and what the publication counts about its reading."
    },
    coverage: %{
      "fr" =>
        "Quelles sources communales officielles brussels.wtf a vérifiées, quand, et quelles réunions ont une couverture sélectionnée.",
      "nl" =>
        "Welke officiële gemeentelijke bronnen brussels.wtf heeft gecontroleerd, wanneer, en welke vergaderingen een geselecteerd verslag hebben.",
      "en" =>
        "Which official municipal sources brussels.wtf checked, when, and which council meetings have selected coverage."
    },
    coming_up: %{
      "fr" =>
        "Points à l’ordre du jour des prochains conseils communaux : des propositions prévues, pas des décisions adoptées.",
      "nl" =>
        "Agendapunten van komende gemeenteraden: geplande voorstellen, geen aangenomen beslissingen.",
      "en" =>
        "Agenda items for upcoming municipal council meetings: scheduled proposals, not adopted decisions."
    },
    awaiting_outcome: %{
      "fr" =>
        "Points de conseils communaux passés sans résultat final vérifié : leur issue reste inconnue tant qu’aucune source officielle ne l’établit.",
      "nl" =>
        "Punten van voorbije gemeenteraden zonder geverifieerd eindresultaat: de uitkomst blijft onbekend zolang geen officiële bron die vastlegt.",
      "en" =>
        "Items from past municipal council meetings with no verified final record: their outcome stays unknown until an official source establishes it."
    },
    decisions: %{
      "fr" =>
        "Décisions de conseils communaux documentées par des comptes rendus officiels, avec leurs citations.",
      "nl" =>
        "Beslissingen van gemeenteraden, gedocumenteerd in officiële eindverslagen, met hun citaten.",
      "en" =>
        "Municipal council decisions documented in official final records, with their citations."
    },
    contested_votes: %{
      "fr" =>
        "Décisions de conseils communaux avec au moins un vote contre ou une abstention enregistrés, et leurs citations officielles.",
      "nl" =>
        "Besluiten van gemeenteraden met minstens één geregistreerde tegenstem of onthouding, met hun officiële citaten.",
      "en" =>
        "Municipal council decisions with at least one recorded vote against or abstention, with their official citations."
    },
    meetings: %{
      "fr" =>
        "Toutes les séances couvertes des conseils communaux, de la plus récente à la plus ancienne.",
      "nl" => "Alle behandelde gemeenteraadsvergaderingen, van de nieuwste naar de oudste.",
      "en" => "Every covered municipal council meeting, newest first."
    },
    mandates: %{
      "fr" => "Mandats publics dans les conseils communaux, établis par des sources officielles.",
      "nl" =>
        "Openbare mandaten in de gemeenteraden, vastgesteld op basis van officiële bronnen.",
      "en" => "Public mandates on municipal councils, established from official sources."
    }
  }

  def fixed(key, locale), do: @fixed |> Map.fetch!(key) |> Map.fetch!(locale)

  def meeting("fr", commune, date),
    do:
      limit(
        "Réunion du conseil de #{commune} du #{date} : points sélectionnés, leur statut et leurs sources officielles."
      )

  def meeting("nl", commune, date),
    do:
      limit(
        "Gemeenteraad van #{commune} van #{date}: geselecteerde punten, hun status en hun officiële bronnen."
      )

  def meeting(_locale, commune, date),
    do:
      limit(
        "#{commune} council meeting of #{date}: selected agenda items, their status and their official sources."
      )

  def dossier("fr", title),
    do:
      limit(
        "Chronologie des points de conseil communal liés au dossier « #{title} », avec leurs sources officielles."
      )

  def dossier("nl", title),
    do:
      limit(
        "Tijdlijn van gemeenteraadspunten in het dossier ‘#{title}’, met hun officiële bronnen."
      )

  def dossier(_locale, title),
    do:
      limit(
        "Timeline of council items linked to the dossier “#{title}”, with their official sources."
      )

  def person("fr", name),
    do: limit("Rôles publics sourcés de #{name}, avec leurs dates et citations officielles.")

  def person("nl", name),
    do:
      limit("Openbare, gedocumenteerde functies van #{name}, met hun data en officiële citaten.")

  def person(_locale, name),
    do: limit("Sourced public roles of #{name}, with their dates and official citations.")

  def company("fr", name),
    do:
      limit(
        "Enregistrement BCE et faits publics sourcés concernant #{name}, avec leurs citations."
      )

  def company("nl", name),
    do: limit("KBO-registratie en gedocumenteerde openbare feiten over #{name}, met hun citaten.")

  def company(_locale, name),
    do: limit("CBE registration and sourced public facts about #{name}, with their citations.")

  defp limit(text) do
    if String.length(text) <= @limit do
      text
    else
      String.slice(text, 0, @limit - 1) <> "…"
    end
  end
end
