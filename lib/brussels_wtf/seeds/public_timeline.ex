defmodule BrusselsWtf.Seeds.PublicTimeline do
  @moduledoc """
  Idempotent, visibly synthetic public records for development and acceptance tests.

  The copy explicitly avoids making claims about real council activity. Links
  point to municipal council landing pages only to exercise citation rendering;
  every such link is marked as a demonstration reference, not claim evidence.
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
      proposal_statement: "Synthetic demonstration proposal — not a municipal matter",
      decision_statement: nil,
      dossier: {"demo-public-space", "DEMO-001"},
      locales: %{
        "en" => %{
          title: "Ixelles demonstration meeting",
          proposal:
            "This synthetic item is presented only as a proposal; it is not a real municipal matter.",
          decision: nil
        },
        "fr" => %{
          title: "Réunion de démonstration d’Ixelles",
          proposal:
            "Ce point synthétique est présenté uniquement comme une proposition ; il ne s’agit pas d’une affaire communale réelle.",
          decision: nil
        },
        "nl" => %{
          title: "Demonstratievergadering van Elsene",
          proposal:
            "Dit synthetische punt wordt alleen als voorstel getoond; het is geen echte gemeentelijke zaak.",
          decision: nil
        }
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
      proposal_statement: "Synthetic demonstration proposal awaiting a final record",
      decision_statement: nil,
      dossier: {"demo-public-space", "DEMO-001"},
      locales: %{
        "en" => %{
          title: "Uccle demonstration meeting",
          proposal: "This synthetic proposal has no authoritative final outcome attached.",
          decision: nil
        },
        "fr" => %{
          title: "Réunion de démonstration d’Uccle",
          proposal: "Aucun résultat final officiel n’est joint à cette proposition synthétique.",
          decision: nil
        },
        "nl" => %{
          title: "Demonstratievergadering van Ukkel",
          proposal: "Aan dit synthetische voorstel is geen officieel eindresultaat gekoppeld.",
          decision: nil
        }
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
      source_wording: "Synthetic demonstration proposal before a final disposition",
      proposal_statement: "Synthetic demonstration proposal before a final disposition",
      decision_statement: "Synthetic demonstration final disposition — postponed",
      dossier: {"demo-facilities", "DEMO-002"},
      locales: %{
        "en" => %{
          title: "Forest demonstration meeting",
          proposal: "The synthetic demonstration item was proposed before the final record.",
          decision:
            "The documented synthetic disposition is postponed; this is not real council activity."
        },
        "fr" => %{
          title: "Réunion de démonstration de Forest",
          proposal: "Le point synthétique a été proposé avant le document final.",
          decision:
            "Le résultat synthétique documenté est un report ; il ne s’agit pas d’une activité communale réelle."
        },
        "nl" => %{
          title: "Demonstratievergadering van Vorst",
          proposal: "Het synthetische punt werd vóór het eindverslag voorgesteld.",
          decision:
            "De gedocumenteerde synthetische beslissing is uitgesteld; dit is geen echte gemeentelijke activiteit."
        }
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
      source_wording: "Synthetic demonstration proposal before a final disposition",
      proposal_statement: "Synthetic demonstration proposal before a final disposition",
      decision_statement: "Synthetic demonstration final disposition — approved",
      dossier: {"demo-administration", "DEMO-003"},
      locales: %{
        "en" => %{
          title: "City of Brussels demonstration meeting",
          proposal: "The synthetic demonstration item was proposed before the final record.",
          decision:
            "The documented synthetic disposition is approved; this is not real council activity."
        },
        "fr" => %{
          title: "Réunion de démonstration de la Ville de Bruxelles",
          proposal: "Le point synthétique a été proposé avant le document final.",
          decision:
            "Le résultat synthétique documenté est une approbation ; il ne s’agit pas d’une activité communale réelle."
        },
        "nl" => %{
          title: "Demonstratievergadering van de Stad Brussel",
          proposal: "Het synthetische punt werd vóór het eindverslag voorgesteld.",
          decision:
            "De gedocumenteerde synthetische beslissing is goedgekeurd; dit is geen echte gemeentelijke activiteit."
        }
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

    Council.upsert_proposal!(%{agenda_item_id: item.id, statement: record.proposal_statement})

    if record.disposition do
      Council.upsert_decision!(%{
        agenda_item_id: item.id,
        disposition: record.disposition,
        statement: record.decision_statement
      })
    end

    Council.upsert_evidence!(%{
      agenda_item_id: item.id,
      citation_url: citation_url,
      source_title: record.source_title,
      location: "Landing page · DEMO",
      retrieved_at: @retrieved_at,
      checksum: nil,
      synthetic: true
    })

    {dossier_slug, dossier_title} = record.dossier
    dossier = Council.upsert_dossier!(%{slug: dossier_slug, title: dossier_title})
    Council.upsert_dossier_link!(%{agenda_item_id: item.id, dossier_id: dossier.id})

    Enum.each(record.locales, fn {locale, variant} ->
      provenance =
        if locale == "fr", do: [:ai_generated], else: [:ai_generated, :machine_translated]

      summary = variant.decision || variant.proposal

      Council.upsert_coverage_variant!(%{
        agenda_item_id: item.id,
        locale: locale,
        title: variant.title,
        summary: summary,
        proposal_summary: variant.proposal,
        decision_summary: variant.decision,
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

    Enum.each(record.locales, fn {locale, variant} ->
      provenance =
        if locale == "fr", do: [:ai_generated], else: [:ai_generated, :machine_translated]

      Council.upsert_locale_variant!(%{
        meeting_page_id: page.id,
        locale: locale,
        title: variant.title,
        summary: variant.decision || variant.proposal,
        provenance: provenance
      })
    end)

    Council.publish_meeting_page!(page)
  end
end
