defmodule BrusselsWtf.Follow.PublicUpdates do
  @moduledoc "Public, publication-gated update read seam. It never stores caller identity or follows. Anonymous reads are limited to 100 distinct targets."
  alias BrusselsWtf.Follow.{Target, TargetEligibility}

  def list(targets, locale) when locale in ~w(fr nl en) and is_list(targets) do
    provider =
      Application.get_env(:brussels_wtf, :public_follow_update_provider, __MODULE__.Published)

    now = Application.fetch_env!(:brussels_wtf, :clock).utc_now()

    targets = Enum.uniq(targets)

    if length(targets) > 100 do
      []
    else
      targets
      |> Enum.flat_map(fn
        %{"type" => type, "id" => id, "importedAt" => imported_at}
        when is_binary(type) and is_binary(id) and is_binary(imported_at) ->
          with {:ok, target} <- Target.new(parse_type(type), id),
               {:ok, imported_at} <- valid_imported_at(imported_at, now),
               true <- TargetEligibility.eligible?(target) do
            provider.list(target, locale, imported_at)
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

  defp valid_imported_at(value, now) do
    with {:ok, timestamp, 0} <- DateTime.from_iso8601(value),
         comparison when comparison in [:lt, :eq] <- DateTime.compare(timestamp, now),
         true <- DateTime.compare(DateTime.shift(timestamp, month: 12), now) in [:gt, :eq] do
      {:ok, timestamp}
    else
      _ -> :error
    end
  end

  @matrix %{
    dossier: [:linked_agenda_item, :decision, :correction, :merge, :split],
    person: [:verified_public_mandate, :verified_management_role, :relevant_council_item],
    legal_entity: [:verified_management_role, :contract_award, :relevant_council_item],
    commune: [:published_meeting_page, :publication_revision_new_decisions]
  }
  @revision_events [
    :linked_agenda_item,
    :decision,
    :correction,
    :merge,
    :split,
    :relevant_council_item,
    :published_meeting_page,
    :publication_revision_new_decisions
  ]
  @fact_events [:verified_public_mandate, :verified_management_role, :contract_award]

  defp valid_update?(
         %{
           target: %{type: type, id: id},
           eventType: event,
           publicEventId: public_id,
           revisionId: revision,
           url: url,
           title: title,
           occurredAt: occurred
         } = update,
         locale
       )
       when event in @revision_events and is_atom(type) and is_binary(id) and is_binary(public_id) and
              is_binary(revision) and is_binary(url) and is_binary(title) and is_binary(occurred) do
    event in Map.get(@matrix, type, []) and public_id != "" and revision != "" and
      not Map.has_key?(update, :factId) and String.contains?(url, "?lang=#{locale}#") and
      Regex.match?(
        ~r{^/meetings/(ixelles|uccle|forest|city-of-brussels)/[A-Za-z0-9._~-]+\?lang=(fr|nl|en)#[A-Za-z0-9._~-]+$},
        url
      )
  end

  defp valid_update?(
         %{
           target: %{type: type, id: id},
           eventType: event,
           publicEventId: public_id,
           factId: fact,
           url: url,
           title: title,
           occurredAt: occurred
         } = update,
         locale
       )
       when event in @fact_events and is_atom(type) and is_binary(id) and is_binary(public_id) and
              is_binary(fact) and is_binary(url) and is_binary(title) and is_binary(occurred) do
    expected_url =
      case type do
        :person -> "/people/#{id}?lang=#{locale}#fact-#{fact}"
        :legal_entity -> "/companies/#{id}?lang=#{locale}#fact-#{fact}"
        _ -> nil
      end

    allowed_keys = [
      :id,
      :target,
      :eventType,
      :publicEventId,
      :factId,
      :url,
      :title,
      :occurredAt
    ]

    event in Map.get(@matrix, type, []) and public_id != "" and fact != "" and
      Regex.match?(~r/^[A-Za-z0-9._~-]+$/, fact) and url == expected_url and
      Enum.all?(Map.keys(update), &(&1 in allowed_keys)) and public_fact?(type, id, fact, event)
  end

  defp valid_update?(_, _), do: false

  defp public_fact?(:person, person_id, fact_id, event) do
    BrusselsWtf.Identity.PublicProjection.list!(%{subject_type: :person, subject_id: person_id})
    |> Enum.any?(fn projection ->
      projection.fact_id == fact_id and fact_event(projection.kind) == event
    end)
  rescue
    _ -> false
  end

  # No legal-entity fact kind has a current evidence/privacy public projection.
  defp public_fact?(:legal_entity, _enterprise_number, _fact_id, _event), do: false
  defp public_fact?(_, _, _, _), do: false

  defp fact_event(:public_mandate), do: :verified_public_mandate
  defp fact_event(:management), do: :verified_management_role
  defp fact_event(:contract), do: :contract_award
  defp fact_event(_), do: :unsupported

  defp parse_type(type) when type in ~w(dossier person legal_entity commune),
    do: String.to_existing_atom(type)

  defp parse_type(_), do: :invalid

  defmodule Published do
    @moduledoc "Projects existing publication-gated meeting state into follow updates."

    def list(%Target{type: type} = target, locale, imported_at)
        when type in [:dossier, :commune] do
      BrusselsWtf.Council.MeetingPage
      |> Ash.Query.for_read(:published)
      |> Ash.read!(authorize?: false, domain: BrusselsWtf.Council)
      |> Ash.load!(
        [:publication_events, council_meeting: [:commune, agenda_items: [:dossier_links]]],
        authorize?: false,
        domain: BrusselsWtf.Council
      )
      |> Enum.flat_map(&page_updates(&1, target, locale, imported_at))
    end

    def list(%Target{type: :person, identifier: person_id} = target, locale, imported_at) do
      BrusselsWtf.Identity.PublicProjection.list!(%{
        subject_type: :person,
        subject_id: person_id
      })
      |> Enum.filter(&DateTime.after?(&1.verified_at, imported_at))
      |> Enum.map(&fact_update(&1, target, locale))
    end

    # Management, contract-award, and relevant-council-item updates stay closed until
    # their persisted claims have a source-specific public projection.
    def list(%Target{type: :legal_entity}, _, _), do: []
    def list(_, _, _), do: []

    defp fact_update(fact, target, locale) do
      %{
        id: "#{target.type}:#{target.identifier}:#{fact.fact_id}",
        target: %{type: target.type, id: target.identifier},
        eventType: :verified_public_mandate,
        publicEventId: fact.fact_id,
        factId: fact.fact_id,
        url: "/people/#{target.identifier}?lang=#{locale}#fact-#{fact.fact_id}",
        title: "#{fact.subject_name} — #{fact.object_name}",
        occurredAt: DateTime.to_iso8601(fact.verified_at)
      }
    end

    defp page_updates(
           page,
           %Target{type: :commune, identifier: slug} = target,
           locale,
           imported_at
         ) do
      if page.council_meeting.commune.slug == slug do
        page.publication_events
        |> Enum.filter(
          &(&1.event_type == :published and is_binary(&1.publication_revision_id) and
              DateTime.after?(&1.occurred_at, imported_at))
        )
        |> Enum.map(&update(&1, target, page, locale, :published_meeting_page, nil))
      else
        []
      end
    end

    defp page_updates(
           page,
           %Target{type: :dossier, identifier: slug} = target,
           locale,
           imported_at
         ) do
      for item <- page.council_meeting.agenda_items,
          link <- item.dossier_links,
          link.status == :active,
          link.disposition == :confirmed,
          link.dossier_id == dossier_id(slug),
          event <- page.publication_events,
          event.event_type in [:published, :factual_correction, :republished],
          is_binary(event.publication_revision_id),
          DateTime.after?(event.occurred_at, imported_at) do
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
