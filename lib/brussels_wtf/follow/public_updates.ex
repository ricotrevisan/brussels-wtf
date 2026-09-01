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
    person: [:verified_public_mandate, :verified_management_role],
    legal_entity: [:verified_management_role, :contract_award],
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
    allowed_url? =
      case event do
        event when event in [:merge, :split] ->
          url == "/dossiers/#{id}?lang=#{locale}#event-#{public_id}" or
            (String.contains?(url, "?lang=#{locale}#") and
               Regex.match?(
                 ~r{^/meetings/(ixelles|uccle|forest|city-of-brussels)/[A-Za-z0-9._~-]+\?lang=(fr|nl|en)#[A-Za-z0-9._~-]+$},
                 url
               ))

        _ ->
          String.contains?(url, "?lang=#{locale}#") and
            Regex.match?(
              ~r{^/meetings/(ixelles|uccle|forest|city-of-brussels)/[A-Za-z0-9._~-]+\?lang=(fr|nl|en)#[A-Za-z0-9._~-]+$},
              url
            )
      end

    event in Map.get(@matrix, type, []) and public_id != "" and revision != "" and
      not Map.has_key?(update, :factId) and allowed_url?
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
    @moduledoc "Projects authoritative persisted public state into follow updates."
    require Ash.Query

    def list(%Target{type: type} = target, locale, imported_at)
        when type in [:dossier, :commune] do
      pages =
        BrusselsWtf.Council.MeetingPage
        |> Ash.Query.for_read(:published)
        |> Ash.read!(authorize?: false, domain: BrusselsWtf.Council)
        |> Ash.load!(
          [
            :publication_events,
            :publication_revisions,
            council_meeting: [
              :commune,
              agenda_items: [:published_decision, dossier_links: [:dossier]]
            ]
          ],
          authorize?: false,
          domain: BrusselsWtf.Council
        )

      updates = Enum.flat_map(pages, &page_updates(&1, target, locale, imported_at))

      case target.type do
        :dossier -> updates ++ dossier_action_updates(target, locale, imported_at)
        _ -> updates
      end
    rescue
      _ -> []
    end

    def list(%Target{type: :person, identifier: person_id} = target, locale, imported_at) do
      BrusselsWtf.Identity.PublicProjection.list!(%{subject_type: :person, subject_id: person_id})
      |> Enum.filter(&DateTime.after?(&1.verified_at, imported_at))
      |> Enum.map(&fact_update(&1, target, locale))
    rescue
      _ -> []
    end

    # Issue #49 remains fail-closed: legal-entity facts have no complete public projection.
    def list(%Target{type: :legal_entity}, _, _), do: []
    def list(_, _, _), do: []

    defp fact_update(fact, target, locale) do
      kind =
        case fact.kind do
          :public_mandate -> :verified_public_mandate
          :management -> :verified_management_role
        end

      %{
        id: "#{target.type}:#{target.identifier}:#{fact.fact_id}",
        target: %{type: target.type, id: target.identifier},
        eventType: kind,
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
        |> Enum.filter(&eligible_publication_event?(&1, page, imported_at))
        |> Enum.flat_map(fn event ->
          case event.event_type do
            :published ->
              [meeting_update(event, target, page, locale, :published_meeting_page, nil)]

            :republished ->
              if revision_adds_decisions?(page, event.publication_revision_id),
                do: [
                  meeting_update(
                    event,
                    target,
                    page,
                    locale,
                    :publication_revision_new_decisions,
                    nil
                  )
                ],
                else: []

            _ ->
              []
          end
        end)
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
      dossier =
        Enum.find_value(page.council_meeting.agenda_items, fn item ->
          Enum.find(item.dossier_links, &(&1.dossier.slug == slug))
        end)

      if is_nil(dossier) do
        []
      else
        Enum.flat_map(page.council_meeting.agenda_items, fn item ->
          links = Enum.filter(item.dossier_links, &public_link?(&1, slug))

          Enum.flat_map(links, fn link ->
            linked =
              if DateTime.after?(link.inserted_at, imported_at),
                do: [meeting_update(link, target, page, locale, :linked_agenda_item, item)],
                else: []

            decision = item.published_decision

            decided =
              if decision && not decision.synthetic && decision.source_version_id &&
                   DateTime.after?(decision.inserted_at, imported_at) do
                [meeting_update(decision, target, page, locale, :decision, item)]
              else
                []
              end

            corrections =
              page.publication_events
              |> Enum.filter(fn event ->
                event.event_type == :factual_correction and
                  eligible_publication_event?(event, page, imported_at)
              end)
              |> Enum.map(&meeting_update(&1, target, page, locale, :correction, item))

            linked ++ decided ++ corrections
          end)
        end)
      end
    end

    defp public_link?(link, slug),
      do: link.status == :active and link.disposition == :confirmed and link.dossier.slug == slug

    defp eligible_publication_event?(event, page, imported_at),
      do:
        is_binary(event.publication_revision_id) and
          event.publication_revision_id == page.current_revision_id and
          DateTime.after?(event.occurred_at, imported_at) and
          event.event_type not in [:typography_correction, :withdrawn]

    defp revision_adds_decisions?(page, revision_id) do
      revision = Enum.find(page.publication_revisions, &(&1.id == revision_id))

      previous =
        revision &&
          Enum.find(page.publication_revisions, &(&1.id == revision.previous_revision_id))

      decision_keys(revision) -- decision_keys(previous) != []
    end

    defp decision_keys(nil), do: []

    defp decision_keys(revision) do
      revision.content
      |> Map.get("items", %{})
      |> Enum.filter(fn {_key, item} ->
        item
        |> Map.get("variants", %{})
        |> Map.values()
        |> Enum.any?(&(Map.get(&1, "decision_summary") not in [nil, ""]))
      end)
      |> Enum.map(&elem(&1, 0))
    end

    defp dossier_action_updates(target, locale, imported_at) do
      dossier = BrusselsWtf.Council.get_dossier!(target.identifier)

      BrusselsWtf.Council.DossierAction
      |> Ash.Query.filter(action in [:merge, :split] and subject_id == ^dossier.id)
      |> Ash.read!(authorize?: false, domain: BrusselsWtf.Council)
      |> Enum.filter(&DateTime.after?(&1.inserted_at, imported_at))
      |> Enum.map(fn action ->
        %{
          id: "dossier:#{target.identifier}:#{action.id}",
          target: %{type: :dossier, id: target.identifier},
          eventType: action.action,
          publicEventId: action.id,
          revisionId: action.id,
          url: "/dossiers/#{target.identifier}?lang=#{locale}#event-#{action.id}",
          title: dossier.title,
          occurredAt: DateTime.to_iso8601(action.inserted_at)
        }
      end)
    rescue
      _ -> []
    end

    defp meeting_update(record, target, page, locale, kind, item) do
      meeting = page.council_meeting

      revision_id =
        if Map.has_key?(record, :publication_revision_id),
          do: record.publication_revision_id,
          else: page.current_revision_id

      occurred_at =
        if Map.has_key?(record, :occurred_at), do: record.occurred_at, else: record.inserted_at

      anchor = if item, do: "##{item.stable_anchor}", else: "#revision-#{revision_id}"

      title =
        if item, do: item.source_wording, else: "#{meeting.commune.name} council publication"

      %{
        id: "#{target.type}:#{target.identifier}:#{record.id}",
        target: %{type: target.type, id: target.identifier},
        eventType: kind,
        publicEventId: record.id,
        revisionId: revision_id,
        url:
          "/meetings/#{meeting.commune.slug}/#{URI.encode(meeting.municipal_identifier)}?lang=#{locale}#{anchor}",
        title: title,
        occurredAt: DateTime.to_iso8601(occurred_at)
      }
    end
  end
end
