defmodule BrusselsWtf.Council.Publication do
  @moduledoc "Orchestrates evidence-gated generation through named Ash actions."

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.CoverageExecution
  alias BrusselsWtf.Council.GenerationContract
  alias BrusselsWtf.Council.PublicationInput
  alias BrusselsWtf.Council.PublicationMetadata
  alias BrusselsWtf.Council.PublicationScope
  alias BrusselsWtf.Council.Provenance
  alias BrusselsWtf.Processors.Coverage
  require Ash.Query

  @locales ["fr", "nl", "en"]

  def generate_and_publish(
        meeting_id,
        attempt \\ 1,
        max_attempts \\ 3,
        generation_kind \\ :automatic,
        coverage_batch_id \\ nil
      ) do
    case BrusselsWtf.Council.GenerationControl.preflight(generation_kind) do
      :ok ->
        metadata = Coverage.metadata() |> attach_content_review(coverage_batch_id)

        case BrusselsWtf.Council.GenerationControl.before_call(metadata, generation_kind) do
          :ok ->
            execute_generation(
              meeting_id,
              metadata,
              attempt,
              max_attempts,
              generation_kind,
              coverage_batch_id
            )

          {:defer, _reason} ->
            :ok
        end

      {:defer, _reason} ->
        :ok
    end
  end

  @doc """
  Publishes one recorded factual correction for an expected published revision.

  The reviewer authorizes the operation, not human-review provenance. All copy
  and processor metadata come from the configured zero-network recorded processor.
  The exact same correction can be retried without adding runs or revisions.
  """
  def recorded_factual_correction!(page_id, expected_revision_id, notes, actor) do
    actor_id = correction_actor!(actor)
    validate_correction_notes!(notes)
    metadata = recorded_correction_metadata!()

    page = Council.get_meeting_page!(page_id)
    meeting = load_meeting(page.council_meeting_id)
    page = meeting.meeting_page

    unless page.publication_status == :published and is_nil(page.withdrawn_at) and
             page.current_revision_id do
      raise ArgumentError, "recorded correction requires a published revision"
    end

    previous = Ash.load!(page.current_revision, [:canonical_run, :nl_run, :en_run])
    {meeting, input} = PublicationScope.restore!(meeting, previous.canonical_run.input)

    cond do
      matching_correction?(previous, expected_revision_id, input, notes, metadata, actor_id) ->
        previous

      previous.id != expected_revision_id ->
        raise ArgumentError, "stale publication revision"

      true ->
        correction = %{
          expected_revision_id: expected_revision_id,
          notes: notes,
          actor_id: actor_id
        }

        # Processor executions are immutable history, even if a later locale or
        # publication gate fails. Only public variants/pointers/revisions belong
        # inside the rollback boundary in publish_revision/6, which locks and
        # rechecks this expected revision before it makes any visible change.
        case generate_revision(meeting, input, metadata, :automatic, 1, correction) do
          {:ok, revision, notifications} ->
            Ash.Notifier.notify(notifications)
            BrusselsWtf.Review.resolve_publication_case!(page_id, revision.publication_input_hash)
            revision

          {:error, {:publication_gate, failures}} ->
            report_gate_failure(meeting, input, failures)
            raise ArgumentError, "publication gate failed: #{inspect(failures)}"

          {:error, {:coverage_processor_failure, failure}} ->
            report_processor_failure(meeting, input, metadata, failure, 1)

            raise ArgumentError,
                  "recorded factual correction failed: #{failure.classification} (#{failure.locale})"

          {:error, :stale_publication_revision} ->
            raise ArgumentError, "stale publication revision"

          {:error, :stale_publication_input} ->
            raise ArgumentError, "stale publication input"

          _failure ->
            raise ArgumentError, "recorded factual correction failed"
        end
    end
  end

  defp correction_actor!(%{id: id, role: :reviewer}) when is_binary(id), do: id

  defp correction_actor!(_actor),
    do: raise(ArgumentError, "recorded correction requires a reviewer")

  defp validate_correction_notes!(notes) do
    unless is_map(notes) and Enum.sort(Map.keys(notes)) == ~w(en fr nl) and
             Enum.all?(notes, fn {_locale, note} ->
               is_binary(note) and String.trim(note) != ""
             end) do
      raise ArgumentError, "correction notes must contain fr, nl, and en"
    end
  end

  defp recorded_correction_metadata! do
    metadata = Coverage.metadata()

    carried =
      Map.get(metadata, :canonical_carried_provenance, []) ++
        Map.get(metadata, :translation_carried_provenance, [])

    unless Council.GenerationControl.mode() == :recorded and
             metadata[:billing_mode] == :recorded and metadata[:network_access] == :none and
             metadata[:canonical_method] in [:ai_generation, :deterministic] and
             metadata[:translation_method] in [:machine_translation, :deterministic] and
             is_nil(metadata[:content_review]) and :human_reviewed not in carried do
      raise ArgumentError, "correction requires unreviewed zero-network recorded generation"
    end

    metadata
  end

  defp matching_correction?(revision, expected_id, input, notes, metadata, actor_id) do
    revision.revision_kind == :factual_correction and
      revision.previous_revision_id == expected_id and revision.actor_id == actor_id and
      revision.correction_notes == notes and
      revision.publication_input_hash == PublicationInput.hash(input) and
      Enum.all?([revision.canonical_run, revision.nl_run, revision.en_run], fn run ->
        run.processor_name == metadata.processor_name and
          run.processor_version == metadata.processor_version and
          run.config_hash == metadata.config_hash
      end)
  end

  defp lock_page!(page_id) do
    Council.MeetingPage
    |> Ash.Query.filter(id == ^page_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(domain: Council)
    |> case do
      nil -> raise ArgumentError, "meeting page does not exist"
      page -> page
    end
  end

  defp execute_generation(
         meeting_id,
         metadata,
         attempt,
         max_attempts,
         generation_kind,
         coverage_batch_id
       ) do
    {meeting, input} =
      meeting_id |> load_meeting() |> PublicationScope.for_batch!(coverage_batch_id)

    result = generate_revision(meeting, input, metadata, generation_kind, attempt, nil)
    handle_result(result, meeting, input, metadata, attempt, max_attempts)
  end

  defp generate_revision(meeting, input, metadata, generation_kind, attempt, correction) do
    page = meeting.meeting_page

    with :ok <- PublicationInput.validate(input),
         {:ok, canonical, canonical_run} <-
           CoverageExecution.canonical(page, input, metadata, generation_kind, attempt),
         :ok <- GenerationContract.validate_bundle(input, canonical, "fr"),
         {:ok, nl, nl_run} <-
           CoverageExecution.translation(
             page,
             canonical_run,
             canonical,
             "nl",
             metadata,
             generation_kind,
             attempt
           ),
         :ok <- GenerationContract.validate_bundle(input, nl, "nl"),
         {:ok, en, en_run} <-
           CoverageExecution.translation(
             page,
             canonical_run,
             canonical,
             "en",
             metadata,
             generation_kind,
             attempt
           ),
         :ok <- GenerationContract.validate_bundle(input, en, "en") do
      output = GenerationContract.combine(canonical, nl, en)

      publish_revision(
        meeting,
        input,
        output,
        %{"fr" => canonical_run, "nl" => nl_run, "en" => en_run},
        metadata[:content_review],
        correction
      )
    end
  end

  defp attach_content_review(metadata, nil), do: metadata

  defp attach_content_review(metadata, coverage_batch_id) do
    batch = Council.get_coverage_batch!(coverage_batch_id)

    if batch.content_reviewed_by && batch.content_reviewed_at &&
         batch.content_review_manifest_sha256 do
      review = %{
        actor_id: batch.content_reviewed_by,
        reviewed_at: batch.content_reviewed_at,
        manifest_sha256: batch.content_review_manifest_sha256
      }

      metadata
      |> Map.put(:content_review, review)
      |> Map.update(:canonical_carried_provenance, [:human_reviewed], fn labels ->
        Enum.uniq([:human_reviewed | labels])
      end)
      |> Map.update(:translation_carried_provenance, [:human_reviewed], fn labels ->
        Enum.uniq([:human_reviewed | labels])
      end)
    else
      metadata
    end
  end

  defp put_content_review(metadata, nil), do: metadata

  defp put_content_review(metadata, review),
    do: Map.put(metadata, "content_review", serialize_content_review(review))

  defp serialize_content_review(review) do
    %{
      "actor_id" => review.actor_id,
      "reviewed_at" => DateTime.to_iso8601(review.reviewed_at),
      "manifest_sha256" => review.manifest_sha256
    }
  end

  def generation_input(meeting_id) when is_binary(meeting_id),
    do: meeting_id |> load_meeting() |> PublicationInput.build()

  def generation_input(meeting), do: PublicationInput.build(meeting)

  defp publish_revision(meeting, input, output, runs, content_review, correction) do
    input_hash = PublicationInput.hash(input)

    transaction =
      BrusselsWtf.Repo.transaction(fn ->
        lock_page!(meeting.meeting_page.id)
        full_meeting = load_meeting(meeting.id)

        if correction &&
             (full_meeting.meeting_page.publication_status != :published or
                not is_nil(full_meeting.meeting_page.withdrawn_at) or
                full_meeting.meeting_page.current_revision_id != correction.expected_revision_id) do
          BrusselsWtf.Repo.rollback(:stale_publication_revision)
        end

        {fresh_meeting, fresh_input} = PublicationScope.restore!(full_meeting, input)

        if PublicationInput.hash(fresh_input) != input_hash do
          BrusselsWtf.Repo.rollback(:stale_publication_input)
        end

        {staged_page, stage_notifications} =
          Council.stage_meeting_page_revision!(
            fresh_meeting.meeting_page,
            return_notifications?: true
          )

        variant_notifications = persist_variants(fresh_meeting, output, runs)

        case Council.evaluate_publication_gate!(fresh_meeting.meeting_page.id, input_hash) do
          %{ready?: true} = gate_result ->
            now = BrusselsWtf.Clock.utc_now()

            metadata =
              PublicationMetadata.build(input, runs, gate_result)
              |> put_content_review(content_review)

            item_state_notifications =
              Enum.flat_map(fresh_meeting.agenda_items, fn item ->
                {_item, notifications} =
                  Council.publish_agenda_item_state!(item, return_notifications?: true)

                notifications
              end)

            scoped_ids = MapSet.new(fresh_meeting.agenda_items, & &1.id)

            excluded_item_notifications =
              full_meeting.agenda_items
              |> Enum.reject(&MapSet.member?(scoped_ids, &1.id))
              |> Enum.flat_map(fn item ->
                {_item, notifications} =
                  Council.unpublish_agenda_item_state!(item, return_notifications?: true)

                notifications
              end)

            {revision, revision_notifications} =
              Council.record_publication_revision!(
                %{
                  meeting_page_id: fresh_meeting.meeting_page.id,
                  publication_input_hash: input_hash,
                  published_at: now,
                  canonical_run_id: runs["fr"].id,
                  nl_run_id: runs["nl"].id,
                  en_run_id: runs["en"].id,
                  content: output,
                  previous_revision_id: fresh_meeting.meeting_page.current_revision_id,
                  revision_kind: if(correction, do: :factual_correction, else: :publication),
                  correction_notes: if(correction, do: correction.notes, else: %{}),
                  actor_id:
                    if(correction,
                      do: correction.actor_id,
                      else: content_review && content_review.actor_id
                    ),
                  publication_metadata: metadata
                },
                return_notifications?: true
              )

            {_event, event_notifications} =
              Council.record_publication_event!(
                %{
                  meeting_page_id: fresh_meeting.meeting_page.id,
                  publication_revision_id: revision.id,
                  event_type: if(correction, do: :factual_correction, else: :published),
                  actor_id: correction && correction.actor_id,
                  occurred_at: now,
                  publication_metadata: metadata,
                  details: %{
                    "previous_revision_id" => fresh_meeting.meeting_page.current_revision_id
                  }
                },
                return_notifications?: true
              )

            {_page, publish_notifications} =
              Council.publish_meeting_page!(
                staged_page,
                %{
                  revision_published_at: now,
                  publication_input_hash: input_hash,
                  gate_input_hash: input_hash,
                  last_gate_failures: [],
                  gate_checked_at: now,
                  current_revision_id: revision.id
                },
                return_notifications?: true
              )

            notifications =
              stage_notifications ++
                variant_notifications ++
                item_state_notifications ++
                excluded_item_notifications ++
                revision_notifications ++
                publish_notifications ++ event_notifications

            {revision, notifications}

          %{ready?: false, failures: failures} ->
            BrusselsWtf.Repo.rollback({:publication_gate, failures})
        end
      end)

    case transaction do
      {:ok, {revision, notifications}} ->
        if correction do
          {:ok, revision, notifications}
        else
          Ash.Notifier.notify(notifications)
          BrusselsWtf.Review.resolve_publication_case!(meeting.meeting_page.id, input_hash)
          :ok
        end

      {:error, reason} when reason in [:stale_publication_input, :stale_publication_revision] ->
        {:error, reason}

      {:error, {:publication_gate, failures}} ->
        {:error, {:publication_gate, failures}}

      {:error, _reason} ->
        {:error, :publication_transaction_failed}
    end
  end

  def persist_variants(meeting, output, runs) do
    page = meeting.meeting_page
    canonical = runs["fr"]

    page_notifications =
      Enum.flat_map(@locales, fn locale ->
        run = runs[locale]
        page_variant = get_in(output, ["page", locale])

        {_variant, notifications} =
          Council.upsert_locale_variant!(
            %{
              meeting_page_id: page.id,
              coverage_run_id: run.id,
              locale: locale,
              title: page_variant["title"],
              summary: page_variant["summary"],
              provenance: Provenance.labels(run, canonical)
            },
            return_notifications?: true
          )

        notifications
      end)

    item_notifications =
      Enum.flat_map(meeting.agenda_items, fn item ->
        item_key = item.authoritative_identifier || item.continuity_key

        Enum.flat_map(@locales, fn locale ->
          run = runs[locale]
          variant = get_in(output, ["items", item_key, "variants", locale])

          {_variant, notifications} =
            Council.upsert_coverage_variant!(
              %{
                agenda_item_id: item.id,
                coverage_run_id: run.id,
                locale: locale,
                title: variant["title"],
                summary: variant["summary"],
                proposal_summary: variant["proposal_summary"],
                decision_summary: variant["decision_summary"],
                provenance: Provenance.labels(run, canonical)
              },
              return_notifications?: true
            )

          notifications
        end)
      end)

    page_notifications ++ item_notifications
  end

  defp handle_result(:ok, _meeting, _input, _metadata, _attempt, _max_attempts), do: :ok

  defp handle_result(
         {:deferred, _reason},
         _meeting,
         _input,
         _metadata,
         _attempt,
         _max_attempts
       ),
       do: :ok

  defp handle_result(
         {:error, {:publication_gate, failures}},
         meeting,
         input,
         _metadata,
         _attempt,
         _max_attempts
       ) do
    report_gate_failure(meeting, input, failures)
    :ok
  end

  defp handle_result(
         {:error, {:coverage_processor_failure, failure}},
         meeting,
         input,
         metadata,
         attempt,
         max_attempts
       ) do
    if attempt >= max_attempts do
      report_processor_failure(meeting, input, metadata, failure, attempt)
      :ok
    else
      {:error, :coverage_processor_failed}
    end
  end

  defp handle_result(other, _meeting, _input, _metadata, _attempt, _max_attempts), do: other

  defp report_gate_failure(meeting, input, failures) do
    page = meeting.meeting_page
    input_hash = PublicationInput.hash(input)
    serialized = Enum.map(failures, &serialize_failure/1)
    now = BrusselsWtf.Clock.utc_now()

    Council.record_publication_gate_failure!(page, %{
      publication_input_hash: input_hash,
      last_gate_failures: serialized,
      gate_checked_at: now
    })

    BrusselsWtf.Review.open_review_case!(%{
      kind: :publication,
      commune_id: meeting.commune_id,
      affected_record_id: page.id,
      affected_record_type: "meeting_page",
      processing_generation: input_hash,
      urgency: :high,
      summary: "Publication gate requires complete localized, evidenced coverage",
      normalized_content: input,
      diagnostics: %{"failures" => serialized}
    })
  end

  defp report_processor_failure(meeting, input, metadata, failure, attempt) do
    input_hash = PublicationInput.hash(input)

    BrusselsWtf.Review.open_review_case!(%{
      kind: :publication,
      commune_id: meeting.commune_id,
      affected_record_id: meeting.meeting_page.id,
      affected_record_type: "meeting_page",
      processing_generation: "#{input_hash}:#{metadata.config_hash}",
      urgency: :high,
      summary: "Coverage processor failed after bounded retries",
      normalized_content: input,
      diagnostics: %{
        "classification" => failure.classification,
        "locale" => failure.locale,
        "coverage_run_id" => failure.run_id,
        "attempt" => attempt
      }
    })
  end

  defp serialize_failure(failure) do
    %{
      "code" => Atom.to_string(failure.code),
      "item_key" => failure.item_key,
      "claim_key" => failure.claim_key,
      "locale" => failure.locale
    }
  end

  def load_meeting(meeting_id) do
    meeting_id
    |> Council.get_meeting!()
    |> Ash.load!([
      :commune,
      meeting_page: [:locale_variants, :current_revision],
      agenda_items: [
        :coverage_variants,
        proposals: [
          source_version: [:source_record],
          evidence: [source_version: [:source_record]]
        ],
        published_proposal: [
          source_version: [:source_record],
          evidence: [source_version: [:source_record]]
        ],
        decision: [
          evidence: [source_version: [:source_record]],
          source_version: [:source_record]
        ]
      ]
    ])
  end
end
