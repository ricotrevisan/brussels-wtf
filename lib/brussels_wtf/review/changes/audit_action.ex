defmodule BrusselsWtf.Review.Changes.AuditAction do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, context) do
    action = Keyword.fetch!(opts, :action)
    effect = Keyword.fetch!(opts, :effect)
    disposition = Keyword.fetch!(opts, :disposition)

    changeset =
      cond do
        action in [:reclassify, :relink] and is_nil(changeset.data.source_record_id) ->
          Ash.Changeset.add_error(changeset,
            field: :source_record_id,
            message: "is required for this review action"
          )

        action == :retry and changeset.data.disposition == :unsupported ->
          Ash.Changeset.add_error(changeset,
            field: :disposition,
            message: "unsupported input is excluded from retry"
          )

        action == :retry and is_nil(changeset.data.source_version_id) ->
          Ash.Changeset.add_error(changeset,
            field: :source_version_id,
            message: "is required to retry processing"
          )

        true ->
          changeset
      end

    status = if Keyword.get(opts, :resolve?, true), do: :resolved, else: :open

    changeset =
      if action == :correct do
        Ash.Changeset.force_change_attribute(
          changeset,
          :normalized_content,
          Ash.Changeset.get_argument(changeset, :corrected_content)
        )
      else
        changeset
      end

    changeset
    |> Ash.Changeset.force_change_attribute(:status, status)
    |> Ash.Changeset.force_change_attribute(:disposition, disposition)
    |> Ash.Changeset.after_action(fn changeset, result ->
      note = Ash.Changeset.get_argument(changeset, :note)
      details = action_details(changeset, action)

      audit =
        BrusselsWtf.Review.record_review_action!(
          %{
            review_case_id: result.id,
            action: action,
            effect: effect,
            disposition: disposition,
            note: note,
            details: details
          },
          actor: context.actor
        )

      append_effect!(result, audit, action, note, details, context.actor)
      {:ok, result}
    end)
  end

  defp action_details(changeset, :retry) do
    metadata = BrusselsWtf.PDF.Processor.metadata()

    (Ash.Changeset.get_argument(changeset, :details) || %{})
    |> Map.put("processor_name", metadata.native_processor_name)
    |> Map.put("processor_version", metadata.native_processor_version)
    |> Map.put("config_hash", metadata.config_hash)
  end

  defp action_details(changeset, :reclassify),
    do: %{"classification" => Ash.Changeset.get_argument(changeset, :classification)}

  defp action_details(changeset, :relink) do
    %{
      "target_record_id" => Ash.Changeset.get_argument(changeset, :target_record_id),
      "target_record_type" => Ash.Changeset.get_argument(changeset, :target_record_type)
    }
  end

  defp action_details(changeset, :correct) do
    %{
      "previous_content" => changeset.data.normalized_content,
      "corrected_content" => Ash.Changeset.get_argument(changeset, :corrected_content)
    }
  end

  defp action_details(changeset, :mark_unsupported),
    do: %{"reason_code" => Ash.Changeset.get_argument(changeset, :reason_code)}

  defp append_effect!(%{source_version_id: version_id}, audit, :retry, note, details, _actor)
       when is_binary(version_id) do
    run =
      BrusselsWtf.Ingestion.create_review_processing_run!(%{
        source_version_id: version_id,
        processor_name: Map.fetch!(details, "processor_name"),
        processor_version: Map.fetch!(details, "processor_version"),
        config_hash: Map.fetch!(details, "config_hash"),
        status: :queued,
        output: %{
          "review_action_id" => audit.id,
          "review_case_id" => audit.review_case_id,
          "note" => note
        }
      })

    %{source_version_id: version_id, processing_run_id: run.id}
    |> BrusselsWtf.Workers.ExtractSource.new()
    |> Oban.insert!()
  end

  defp append_effect!(_review_case, _audit, :retry, _note, _details, _actor), do: :ok

  defp append_effect!(review_case, audit, action, note, details, actor)
       when action in [:reclassify, :relink, :correct] do
    kind = %{reclassify: :reclassification, relink: :relink, correct: :correction}[action]

    BrusselsWtf.Review.record_review_revision!(
      %{
        review_case_id: review_case.id,
        review_action_id: audit.id,
        kind: kind,
        details: details,
        note: note
      },
      actor: actor
    )

    apply_domain_revision!(review_case, action, details)
  end

  defp append_effect!(review_case, audit, :mark_unsupported, note, details, actor) do
    BrusselsWtf.Review.record_review_exclusion!(
      %{
        review_case_id: review_case.id,
        review_action_id: audit.id,
        affected_record_id: review_case.affected_record_id,
        processing_generation: review_case.processing_generation,
        reason: note,
        details: details
      },
      actor: actor
    )
  end

  defp apply_domain_revision!(%{source_record_id: source_record_id}, :reclassify, details)
       when is_binary(source_record_id) do
    source_record = BrusselsWtf.Ingestion.get_source_record!(source_record_id)

    BrusselsWtf.Ingestion.reclassify_source_record!(source_record, %{
      role: Map.fetch!(details, "classification")
    })
  end

  defp apply_domain_revision!(%{source_record_id: source_record_id}, :relink, %{
         "target_record_id" => target_record_id,
         "target_record_type" => :council_meeting
       })
       when is_binary(source_record_id) do
    source_record = BrusselsWtf.Ingestion.get_source_record!(source_record_id)

    BrusselsWtf.Ingestion.link_source_record_to_meeting!(source_record, %{
      council_meeting_id: target_record_id
    })
  end

  defp apply_domain_revision!(_review_case, _action, _details), do: :ok
end
