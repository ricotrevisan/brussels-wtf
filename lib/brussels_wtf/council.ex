defmodule BrusselsWtf.Council do
  @moduledoc """
  Normalized meetings, agenda items, and publishable meeting pages.
  """

  use Ash.Domain, otp_app: :brussels_wtf

  resources do
    resource BrusselsWtf.Council.Meeting do
      define :get_meeting, action: :read, get_by: [:id]
      define :upsert_meeting, action: :upsert

      define :get_ingested_meeting,
        action: :ingested_by_identity,
        args: [:commune_slug, :municipal_identifier]
    end

    resource BrusselsWtf.Council.Agenda do
      define :record_agenda, action: :record
    end

    resource BrusselsWtf.Council.AgendaItem do
      define :upsert_agenda_item, action: :upsert
      define :upsert_rendered_agenda_item, action: :upsert_rendered
      define :mark_agenda_item_proposed, action: :mark_proposed
    end

    resource BrusselsWtf.Council.AgendaItemVersion do
      define :record_agenda_item_version, action: :record
    end

    resource BrusselsWtf.Council.Proposal do
      define :record_proposal, action: :record
      define :upsert_proposal, action: :upsert_rendered
    end

    resource BrusselsWtf.Council.Evidence do
      define :record_evidence, action: :record
      define :upsert_evidence, action: :upsert_reference
    end

    resource BrusselsWtf.Council.Decision do
      define :upsert_decision, action: :upsert
    end

    resource BrusselsWtf.Council.Dossier do
      define :upsert_dossier, action: :upsert
      define :get_dossier, action: :by_slug, args: [:slug]
    end

    resource BrusselsWtf.Council.DossierLink do
      define :upsert_dossier_link, action: :upsert
    end

    resource BrusselsWtf.Council.CoverageVariant do
      define :upsert_coverage_variant, action: :upsert
    end

    resource BrusselsWtf.Council.CoverageRun do
      define :record_coverage_run, action: :record
      define :list_coverage_runs, action: :for_page, args: [:meeting_page_id]
    end

    resource BrusselsWtf.Council.MeetingPage do
      define :get_meeting_page, action: :read, get_by: [:id]
      define :upsert_meeting_page, action: :upsert
      define :record_publication_gate_failure, action: :record_gate_failure
      define :publish_meeting_page, action: :publish
      define :list_published_meeting_pages, action: :published

      define :get_published_meeting_page,
        action: :published_by_identity,
        args: [:commune_slug, :municipal_identifier]
    end

    resource BrusselsWtf.Council.LocaleVariant do
      define :upsert_locale_variant, action: :upsert
      define :list_locale_variants, action: :for_page, args: [:meeting_page_id]
    end
  end

  @doc "Returns the last evaluated publication gate result for one meeting page."
  def publication_readiness!(meeting_page_id) do
    page = get_meeting_page!(meeting_page_id)

    %{
      ready?: page.publication_status == :published and page.last_gate_failures == [],
      input_hash: page.publication_input_hash,
      checked_at: page.gate_checked_at,
      failures: Enum.map(page.last_gate_failures, &atomize_gate_failure/1)
    }
  end

  defp atomize_gate_failure(failure) do
    %{
      code: failure["code"] |> String.to_existing_atom(),
      item_key: failure["item_key"],
      claim_key: failure["claim_key"],
      locale: failure["locale"]
    }
  end
end
