defmodule BrusselsWtf.Council.PublicationLifecycle do
  @moduledoc "Authorized factual correction, typography, withdrawal, and republication commands."

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.GenerationContract
  alias BrusselsWtf.Council.Publication
  alias BrusselsWtf.Council.PublicationInput
  alias BrusselsWtf.Council.PublicationMetadata

  @locales ["fr", "nl", "en"]

  def factual_correction!(page_id, bundles, notes, actor) do
    actor_id = reviewer_id!(actor)
    validate_locale_map!(bundles, "correction bundles")
    validate_locale_map!(notes, "correction notes", &present?/1)

    meeting = meeting_for_page!(page_id)
    page = current_page!(meeting)
    ensure_published!(page)
    input = PublicationInput.build(meeting)
    validate_bundles!(input, bundles)
    content = GenerationContract.combine(bundles["fr"], bundles["nl"], bundles["en"])

    publish_editorial_revision!(
      meeting,
      page,
      input,
      bundles,
      content,
      :factual_correction,
      notes,
      actor_id,
      @locales
    )
  end

  def typography_correction!(page_id, locale, bundle, actor) when locale in @locales do
    actor_id = reviewer_id!(actor)
    meeting = meeting_for_page!(page_id)
    page = current_page!(meeting)
    ensure_published!(page)
    input = PublicationInput.build(meeting)
    :ok = validate_bundle!(input, bundle, locale)

    previous = load_revision!(page.current_revision)

    bundles =
      Map.new(@locales, fn current_locale ->
        current_bundle = bundle_from_content(previous.content, current_locale)
        {current_locale, if(current_locale == locale, do: bundle, else: current_bundle)}
      end)

    content = GenerationContract.combine(bundles["fr"], bundles["nl"], bundles["en"])

    publish_editorial_revision!(
      meeting,
      page,
      input,
      bundles,
      content,
      :typography_correction,
      %{},
      actor_id,
      [locale]
    )
  end

  def withdraw!(page_id, reasons, actor) do
    actor_id = reviewer_id!(actor)
    validate_locale_map!(reasons, "withdrawal notices", &present?/1)
    meeting = meeting_for_page!(page_id)
    page = current_page!(meeting)
    ensure_published!(page)
    revision = load_revision!(page.current_revision)
    occurred_at = BrusselsWtf.Clock.utc_now()

    transact!(fn ->
      {_page, page_notifications} =
        Council.withdraw_meeting_page!(
          page,
          %{reasons: reasons, occurred_at: occurred_at},
          actor: actor,
          return_notifications?: true
        )

      {_event, event_notifications} =
        Council.record_publication_event!(
          %{
            meeting_page_id: page.id,
            publication_revision_id: revision.id,
            event_type: :withdrawn,
            actor_id: actor_id,
            occurred_at: occurred_at,
            publication_metadata: revision.publication_metadata,
            details: %{"reasons" => reasons}
          },
          return_notifications?: true
        )

      {page, page_notifications ++ event_notifications}
    end)
  end

  def republish!(page_id, actor) do
    actor_id = reviewer_id!(actor)
    meeting = meeting_for_page!(page_id)
    page = current_page!(meeting)
    ensure_withdrawn!(page)
    previous = load_revision!(page.current_revision)
    input = PublicationInput.build(meeting)
    input_hash = PublicationInput.hash(input)

    if input_hash != previous.publication_input_hash do
      raise ArgumentError, "withdrawn content is stale and requires a new generated revision"
    end

    runs = revision_runs(previous)

    transact!(fn ->
      gate_result = Council.evaluate_publication_gate!(page.id, input_hash)

      if not gate_result.ready? do
        BrusselsWtf.Repo.rollback({:publication_gate, gate_result.failures})
      end

      occurred_at = BrusselsWtf.Clock.utc_now()
      metadata = PublicationMetadata.build(input, runs, gate_result)

      {revision, revision_notifications} =
        Council.record_publication_revision!(
          revision_attrs(
            page,
            previous,
            runs,
            previous.content,
            input_hash,
            occurred_at,
            :republication,
            %{},
            actor_id,
            metadata
          ),
          return_notifications?: true
        )

      {_page, page_notifications} =
        publish_page!(page, revision, input_hash, occurred_at)

      {_event, event_notifications} =
        record_event!(
          page,
          revision,
          :republished,
          actor_id,
          occurred_at,
          metadata,
          %{"withdrawn_at" => DateTime.to_iso8601(page.withdrawn_at)}
        )

      {revision, revision_notifications ++ page_notifications ++ event_notifications}
    end)
  end

  defp publish_editorial_revision!(
         meeting,
         page,
         input,
         bundles,
         content,
         kind,
         notes,
         actor_id,
         affected_locales
       ) do
    previous = load_revision!(page.current_revision)
    input_hash = PublicationInput.hash(input)
    occurred_at = BrusselsWtf.Clock.utc_now()

    transact!(fn ->
      {staged_page, stage_notifications} =
        Council.stage_meeting_page_revision!(page, return_notifications?: true)

      {runs, run_notifications} =
        record_editorial_runs!(page, input, input_hash, bundles, kind)

      variant_notifications = Publication.persist_variants(meeting, content, runs)
      gate_result = Council.evaluate_publication_gate!(page.id, input_hash)

      if not gate_result.ready? do
        BrusselsWtf.Repo.rollback({:publication_gate, gate_result.failures})
      end

      metadata = PublicationMetadata.build(input, runs, gate_result)

      {revision, revision_notifications} =
        Council.record_publication_revision!(
          revision_attrs(
            page,
            previous,
            runs,
            content,
            input_hash,
            occurred_at,
            kind,
            notes,
            actor_id,
            metadata
          ),
          return_notifications?: true
        )

      {_page, page_notifications} =
        publish_page!(staged_page, revision, input_hash, occurred_at)

      {_event, event_notifications} =
        record_event!(
          page,
          revision,
          kind,
          actor_id,
          occurred_at,
          metadata,
          %{"affected_locales" => affected_locales}
        )

      {revision,
       stage_notifications ++
         run_notifications ++
         variant_notifications ++
         revision_notifications ++ page_notifications ++ event_notifications}
    end)
  end

  defp record_editorial_runs!(page, input, input_hash, bundles, kind) do
    prior = prior_provenance(page)

    {canonical, canonical_notifications} =
      record_editorial_run!(
        %{
          meeting_page_id: page.id,
          operation: :canonical_generation,
          locale: "fr",
          input_hash: input_hash,
          input: input,
          output: bundles["fr"],
          carried_provenance: prior["fr"]
        },
        kind,
        nil
      )

    {nl, nl_notifications} =
      record_editorial_translation!(page, canonical, bundles, "nl", prior, kind)

    {en, en_notifications} =
      record_editorial_translation!(page, canonical, bundles, "en", prior, kind)

    {%{"fr" => canonical, "nl" => nl, "en" => en},
     canonical_notifications ++ nl_notifications ++ en_notifications}
  end

  defp record_editorial_translation!(page, canonical, bundles, locale, prior, kind) do
    input = %{
      "canonical_output_hash" => canonical.output_hash,
      "canonical" => bundles["fr"],
      "locale" => locale
    }

    record_editorial_run!(
      %{
        meeting_page_id: page.id,
        parent_run_id: canonical.id,
        operation: :translation,
        locale: locale,
        input_hash: PublicationInput.hash(input),
        input: input,
        output: bundles[locale],
        carried_provenance: prior[locale]
      },
      kind,
      canonical.id
    )
  end

  defp record_editorial_run!(attrs, kind, parent_run_id) do
    output = attrs.output

    Council.record_coverage_run!(
      Map.merge(attrs, %{
        parent_run_id: parent_run_id,
        output_hash: PublicationInput.hash(output),
        processor_name: "editorial-publication-lifecycle",
        processor_version: "1",
        config_hash: PublicationInput.hash(%{"kind" => kind, "processor_version" => "1"}),
        provider_category: "human_editor",
        model: nil,
        method: :human_edit,
        status: :succeeded,
        usage: %{},
        duration_ms: 0,
        failure_details: %{}
      }),
      return_notifications?: true
    )
  end

  defp revision_attrs(
         page,
         previous,
         runs,
         content,
         input_hash,
         occurred_at,
         kind,
         notes,
         actor_id,
         metadata
       ) do
    %{
      meeting_page_id: page.id,
      previous_revision_id: previous.id,
      publication_input_hash: input_hash,
      published_at: occurred_at,
      canonical_run_id: runs["fr"].id,
      nl_run_id: runs["nl"].id,
      en_run_id: runs["en"].id,
      content: content,
      revision_kind: kind,
      correction_notes: notes,
      actor_id: actor_id,
      publication_metadata: metadata
    }
  end

  defp publish_page!(page, revision, input_hash, occurred_at) do
    Council.publish_meeting_page!(
      page,
      %{
        revision_published_at: occurred_at,
        publication_input_hash: input_hash,
        gate_input_hash: input_hash,
        last_gate_failures: [],
        gate_checked_at: occurred_at,
        current_revision_id: revision.id
      },
      return_notifications?: true
    )
  end

  defp record_event!(page, revision, type, actor_id, occurred_at, metadata, details) do
    Council.record_publication_event!(
      %{
        meeting_page_id: page.id,
        publication_revision_id: revision.id,
        event_type: type,
        actor_id: actor_id,
        occurred_at: occurred_at,
        publication_metadata: metadata,
        details: details
      },
      return_notifications?: true
    )
  end

  defp prior_provenance(page) do
    variants =
      page.locale_variants ++
        Enum.flat_map(page.council_meeting.agenda_items, & &1.coverage_variants)

    Map.new(@locales, fn locale ->
      values =
        variants
        |> Enum.filter(&(&1.locale == locale))
        |> Enum.flat_map(& &1.provenance)
        |> Enum.uniq()

      {locale, values}
    end)
  end

  defp revision_runs(revision) do
    %{"fr" => revision.canonical_run, "nl" => revision.nl_run, "en" => revision.en_run}
  end

  defp bundle_from_content(content, locale) do
    %{
      "page" => content["page"][locale],
      "items" =>
        Map.new(content["items"], fn {item_key, item} ->
          {item_key, %{"claim_refs" => item["claim_refs"], "variant" => item["variants"][locale]}}
        end)
    }
  end

  defp validate_bundles!(input, bundles) do
    Enum.each(@locales, &validate_bundle!(input, bundles[&1], &1))
  end

  defp validate_bundle!(input, bundle, locale) do
    case GenerationContract.validate_bundle(input, bundle, locale) do
      :ok -> :ok
      {:error, _reason} -> raise ArgumentError, "invalid #{locale} editorial coverage bundle"
    end
  end

  defp validate_locale_map!(map, name, predicate \\ &is_map/1) do
    valid? =
      is_map(map) and MapSet.new(Map.keys(map)) == MapSet.new(@locales) and
        Enum.all?(Map.values(map), predicate)

    if not valid?, do: raise(ArgumentError, "#{name} must contain fr, nl, and en")
  end

  defp meeting_for_page!(page_id) do
    page = Council.get_meeting_page!(page_id)
    Publication.load_meeting(page.council_meeting_id)
  end

  defp current_page!(meeting) do
    meeting.meeting_page
    |> Ash.load!([
      :current_revision,
      :locale_variants,
      council_meeting: [agenda_items: [:coverage_variants]]
    ])
  end

  defp load_revision!(nil), do: raise(ArgumentError, "meeting page has no publication revision")

  defp load_revision!(revision) do
    Ash.load!(revision, [:canonical_run, :nl_run, :en_run])
  end

  defp ensure_published!(%{publication_status: :published, current_revision_id: id})
       when is_binary(id),
       do: :ok

  defp ensure_published!(_page),
    do: raise(ArgumentError, "meeting page must have a published revision")

  defp ensure_withdrawn!(%{publication_status: :draft, withdrawn_at: %DateTime{}}), do: :ok
  defp ensure_withdrawn!(_page), do: raise(ArgumentError, "meeting page is not withdrawn")

  defp reviewer_id!(%{id: actor_id, role: :reviewer}) when is_binary(actor_id), do: actor_id
  defp reviewer_id!(_actor), do: raise(ArgumentError, "publication action requires a reviewer")

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp transact!(fun) do
    case BrusselsWtf.Repo.transaction(fun) do
      {:ok, {result, notifications}} ->
        Ash.Notifier.notify(notifications)
        result

      {:error, {:publication_gate, failures}} ->
        raise ArgumentError, "publication gate failed: #{inspect(failures)}"

      {:error, reason} ->
        raise "publication lifecycle transaction failed: #{inspect(reason)}"
    end
  end
end
