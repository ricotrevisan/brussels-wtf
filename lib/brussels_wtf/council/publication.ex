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

    page = meeting.meeting_page

    result =
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
          metadata[:content_review]
        )
      end

    handle_result(result, meeting, input, metadata, attempt, max_attempts)
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

  defp publish_revision(meeting, input, output, runs, content_review) do
    input_hash = PublicationInput.hash(input)

    transaction =
      BrusselsWtf.Repo.transaction(fn ->
        full_meeting = load_meeting(meeting.id)
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
                  revision_kind: :publication,
                  correction_notes: %{},
                  actor_id: content_review && content_review.actor_id,
                  publication_metadata: metadata
                },
                return_notifications?: true
              )

            {_event, event_notifications} =
              Council.record_publication_event!(
                %{
                  meeting_page_id: fresh_meeting.meeting_page.id,
                  publication_revision_id: revision.id,
                  event_type: :published,
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

            stage_notifications ++
              variant_notifications ++
              item_state_notifications ++
              excluded_item_notifications ++
              revision_notifications ++
              publish_notifications ++ event_notifications

          %{ready?: false, failures: failures} ->
            BrusselsWtf.Repo.rollback({:publication_gate, failures})
        end
      end)

    case transaction do
      {:ok, notifications} ->
        Ash.Notifier.notify(notifications)
        BrusselsWtf.Review.resolve_publication_case!(meeting.meeting_page.id, input_hash)
        :ok

      {:error, :stale_publication_input} ->
        {:error, :stale_publication_input}

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
