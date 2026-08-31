defmodule BrusselsWtf.Follow.PublicUpdates do
  @moduledoc "Public, publication-gated update read seam. It never stores caller identity or follows. Anonymous reads are limited to 100 distinct targets."
  alias BrusselsWtf.Follow.{Target, TargetEligibility}

  def list(targets, locale) when locale in ~w(fr nl en) and is_list(targets) do
    provider =
      Application.get_env(:brussels_wtf, :public_follow_update_provider, __MODULE__.Published)

    targets = Enum.uniq(targets)

    if length(targets) > 100 do
      []
    else
      targets
      |> Enum.flat_map(fn
        %{"type" => type, "id" => id} when is_binary(type) and is_binary(id) ->
          with {:ok, target} <- Target.new(parse_type(type), id),
               true <- TargetEligibility.eligible?(target) do
            provider.list(target, locale)
            |> Enum.filter(fn
              %{target: %{type: output_type, id: output_id}} ->
                output_type == target.type and output_id == target.identifier

              _ ->
                false
            end)
          else
            _ -> []
          end

        _malformed ->
          []
      end)
      |> Enum.filter(&valid_update?(&1, locale))
    end
  end

  def list(_, _), do: []

  @matrix %{
    dossier: [:linked_agenda_item, :decision, :correction, :merge, :split],
    person: [:verified_public_mandate, :verified_management_role, :relevant_council_item],
    legal_entity: [:verified_management_role, :contract_award, :relevant_council_item],
    commune: [:published_meeting_page, :publication_revision_new_decisions]
  }
  defp valid_update?(
         %{
           target: %{type: type, id: id},
           eventType: event,
           publicEventId: public_id,
           revisionId: revision,
           url: url,
           title: title,
           occurredAt: occurred
         },
         locale
       )
       when is_atom(type) and is_binary(id) and is_atom(event) and is_binary(public_id) and
              is_binary(revision) and is_binary(url) and is_binary(title) and is_binary(occurred) do
    event in Map.get(@matrix, type, []) and public_id != "" and revision != "" and
      String.contains?(url, "?lang=#{locale}#") and
      Regex.match?(
        ~r{^/meetings/(ixelles|uccle|forest|city-of-brussels)/[A-Za-z0-9._~-]+\?lang=(fr|nl|en)#[A-Za-z0-9._~-]+$},
        url
      )
  end

  defp valid_update?(_, _), do: false

  defp parse_type(type) when type in ~w(dossier person legal_entity commune),
    do: String.to_existing_atom(type)

  defp parse_type(_), do: :invalid

  defmodule Published do
    @moduledoc "Projects existing publication-gated meeting state into follow updates."

    def list(%Target{type: type} = target, locale) when type in [:dossier, :commune] do
      BrusselsWtf.Council.MeetingPage
      |> Ash.Query.for_read(:published)
      |> Ash.read!(authorize?: false, domain: BrusselsWtf.Council)
      |> Ash.load!(
        [:publication_events, council_meeting: [:commune, agenda_items: [:dossier_links]]],
        authorize?: false,
        domain: BrusselsWtf.Council
      )
      |> Enum.flat_map(&page_updates(&1, target, locale))
    end

    def list(_, _), do: []

    defp page_updates(page, %Target{type: :commune, identifier: slug} = target, locale) do
      if page.council_meeting.commune.slug == slug do
        page.publication_events
        |> Enum.filter(&(&1.event_type == :published and is_binary(&1.publication_revision_id)))
        |> Enum.map(&update(&1, target, page, locale, :published_meeting_page, nil))
      else
        []
      end
    end

    defp page_updates(page, %Target{type: :dossier, identifier: slug} = target, locale) do
      for item <- page.council_meeting.agenda_items,
          link <- item.dossier_links,
          link.status == :active,
          link.disposition == :confirmed,
          link.dossier_id == dossier_id(slug),
          event <- page.publication_events,
          event.event_type in [:published, :factual_correction, :republished],
          is_binary(event.publication_revision_id) do
        kind =
          if item.published_procedural_state == :decision,
            do: :decision,
            else: :linked_agenda_item

        update(event, target, page, locale, kind, item)
      end
    end

    defp update(event, target, page, locale, kind, item) do
      meeting = page.council_meeting

      anchor =
        if item, do: "##{item.stable_anchor}", else: "#revision-#{event.publication_revision_id}"

      title =
        if item, do: item.source_wording, else: "#{meeting.commune.name} council publication"

      %{
        id: "#{target.type}:#{target.identifier}:#{event.id}",
        target: %{type: target.type, id: target.identifier},
        eventType: kind,
        publicEventId: event.id,
        revisionId: event.publication_revision_id,
        url:
          "/meetings/#{meeting.commune.slug}/#{URI.encode(meeting.municipal_identifier)}?lang=#{locale}#{anchor}",
        title: title,
        occurredAt: DateTime.to_iso8601(event.occurred_at)
      }
    end

    defp dossier_id(slug) do
      case BrusselsWtf.Council.get_dossier(slug) do
        {:ok, dossier} -> dossier.id
        _ -> nil
      end
    end
  end
end
