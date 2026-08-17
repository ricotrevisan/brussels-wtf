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
      define :mark_agenda_item_proposed, action: :mark_proposed
    end

    resource BrusselsWtf.Council.AgendaItemVersion do
      define :record_agenda_item_version, action: :record
    end

    resource BrusselsWtf.Council.Proposal do
      define :record_proposal, action: :record
    end

    resource BrusselsWtf.Council.Evidence do
      define :record_evidence, action: :record
    end

    resource BrusselsWtf.Council.MeetingPage do
      define :get_meeting_page, action: :read, get_by: [:id]
      define :upsert_meeting_page, action: :upsert
      define :publish_meeting_page, action: :publish

      define :get_published_meeting_page,
        action: :published_by_identity,
        args: [:commune_slug, :municipal_identifier]
    end

    resource BrusselsWtf.Council.LocaleVariant do
      define :upsert_locale_variant, action: :upsert
      define :list_locale_variants, action: :for_page, args: [:meeting_page_id]
    end
  end
end
