defmodule BrusselsWtf.Seeds.PublicTimeline do
  @moduledoc """
  Idempotent, visibly synthetic public records for development and acceptance tests.

  The copy explicitly avoids making claims about real council activity. Citations
  use the authoritative municipal council landing pages to exercise the public
  evidence presentation without pretending the seed is an official record.
  """

  alias BrusselsWtf.Council
  alias BrusselsWtf.Ingestion

  @retrieved_at ~U[2026-08-15 09:00:00.000000Z]
  @revision_at ~U[2026-08-16 12:00:00.000000Z]

  @records [
    %{
      commune: {"ixelles", "Ixelles", "https://www.ixelles.be/site/65-Conseil-communal"},
      meeting_id: "demo-ixelles",
      scheduled_on: ~D[2026-09-15],
      number: "1",
      anchor: "agenda-item-mobility-1",
      state: :proposal,
      disposition: nil,
      source_title: "Conseil communal d’Ixelles",
      source_wording: "Synthetic demonstration proposal — not a municipal matter",
      dossier: {"demo-public-space", "DEMO-001"},
      locales: %{
        "en" =>
          {"Ixelles demonstration meeting",
           "Demonstration proposal — this is not a real municipal matter."},
        "fr" =>
          {"Réunion de démonstration d’Ixelles",
           "Proposition de démonstration — il ne s’agit pas d’une affaire communale réelle."},
        "nl" =>
          {"Demonstratievergadering van Elsene",
           "Demonstratievoorstel — dit is geen echte gemeentelijke zaak."}
      }
    },
    %{
      commune: {"uccle", "Uccle", "https://www.uccle.be/fr/vie-politique/conseil-communal"},
      meeting_id: "demo-uccle",
      scheduled_on: ~D[2026-08-20],
      number: "7",
      anchor: "agenda-item-public-space-7",
      state: :unknown,
      disposition: nil,
      source_title: "Conseil communal d’Uccle",
      source_wording: "Synthetic demonstration item awaiting a final record",
      dossier: {"demo-public-space", "DEMO-001"},
      locales: %{
        "en" =>
          {"Uccle demonstration meeting",
           "Demonstration item; no authoritative final outcome is recorded."},
        "fr" =>
          {"Réunion de démonstration d’Uccle",
           "Point de démonstration ; aucun résultat final officiel n’est enregistré."},
        "nl" =>
          {"Demonstratievergadering van Ukkel",
           "Demonstratiepunt; er is geen officieel eindresultaat vastgelegd."}
      }
    },
    %{
      commune: {"forest", "Forest", "https://forest.brussels/fr/vie-politique/conseil-communal"},
      meeting_id: "demo-forest",
      scheduled_on: ~D[2026-07-08],
      number: "12",
      anchor: "agenda-item-facilities-12",
      state: :decision,
      disposition: :postponed,
      source_title: "Conseil communal de Forest",
      source_wording: "Synthetic demonstration decision — postponed",
      dossier: {"demo-facilities", "DEMO-002"},
      locales: %{
        "en" =>
          {"Forest demonstration meeting",
           "Synthetic demonstration decision: postponed; not real council activity."},
        "fr" =>
          {"Réunion de démonstration de Forest",
           "Décision de démonstration : reportée ; ce n’est pas une activité communale réelle."},
        "nl" =>
          {"Demonstratievergadering van Vorst",
           "Demonstratiebesluit: uitgesteld; geen echte gemeentelijke activiteit."}
      }
    },
    %{
      commune: {"city-of-brussels", "City of Brussels", "https://www.brussels.be/city-council"},
      meeting_id: "demo-brussels",
      scheduled_on: ~D[2026-06-22],
      number: "3",
      anchor: "agenda-item-administration-3",
      state: :decision,
      disposition: :approved,
      source_title: "Conseil communal / Gemeenteraad",
      source_wording: "Synthetic demonstration decision — approved",
      dossier: {"demo-administration", "DEMO-003"},
      locales: %{
        "en" =>
          {"City of Brussels demonstration meeting",
           "Synthetic demonstration decision: approved; not real council activity."},
        "fr" =>
          {"Réunion de démonstration de la Ville de Bruxelles",
           "Décision de démonstration : approuvée ; ce n’est pas une activité communale réelle."},
        "nl" =>
          {"Demonstratievergadering van de Stad Brussel",
           "Demonstratiebesluit: goedgekeurd; geen echte gemeentelijke activiteit."}
      }
    }
  ]

  @spec run!() :: :ok
  def run! do
    Enum.each(@records, &store_record!/1)
    :ok
  end

  defp store_record!(record) do
    {slug, name, citation_url} = record.commune

    commune = Ingestion.create_commune!(%{slug: slug, name: name, index_url: citation_url})

    meeting =
      Council.upsert_meeting!(%{
        commune_id: commune.id,
        municipal_identifier: record.meeting_id,
        scheduled_on: record.scheduled_on
      })

    item =
      Council.upsert_agenda_item!(%{
        council_meeting_id: meeting.id,
        item_number: record.number,
        stable_anchor: record.anchor,
        source_wording: record.source_wording,
        procedural_state: record.state
      })

    Council.upsert_proposal!(%{agenda_item_id: item.id, statement: record.source_wording})

    if record.disposition do
      Council.upsert_decision!(%{
        agenda_item_id: item.id,
        disposition: record.disposition,
        statement: record.source_wording
      })
    end

    Council.upsert_evidence!(%{
      agenda_item_id: item.id,
      citation_url: citation_url,
      source_title: record.source_title,
      location: "Landing page · DEMO",
      retrieved_at: @retrieved_at,
      checksum: BrusselsWtf.Digest.sha256("synthetic evidence snapshot: #{record.source_wording}")
    })

    {dossier_slug, dossier_title} = record.dossier
    dossier = Council.upsert_dossier!(%{slug: dossier_slug, title: dossier_title})
    Council.upsert_dossier_link!(%{agenda_item_id: item.id, dossier_id: dossier.id})

    Enum.each(record.locales, fn {locale, {title, summary}} ->
      provenance =
        if locale == "fr", do: [:ai_generated], else: [:ai_generated, :machine_translated]

      Council.upsert_coverage_variant!(%{
        agenda_item_id: item.id,
        locale: locale,
        title: title,
        summary: summary,
        provenance: provenance
      })
    end)

    page =
      Council.upsert_meeting_page!(%{
        council_meeting_id: meeting.id,
        citation_url: citation_url,
        procedural_state: record.state,
        revision_published_at: @revision_at
      })

    Enum.each(record.locales, fn {locale, {title, summary}} ->
      provenance =
        if locale == "fr", do: [:ai_generated], else: [:ai_generated, :machine_translated]

      Council.upsert_locale_variant!(%{
        meeting_page_id: page.id,
        locale: locale,
        title: title,
        summary: summary,
        provenance: provenance
      })
    end)

    Council.publish_meeting_page!(page)
  end
end
