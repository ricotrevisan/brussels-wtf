defmodule BrusselsWtf.Review.Changes.AuditAction do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, context) do
    action = Keyword.fetch!(opts, :action)
    effect = Keyword.fetch!(opts, :effect)
    disposition = Keyword.fetch!(opts, :disposition)

    changeset
    |> Ash.Changeset.force_change_attribute(:status, :resolved)
    |> Ash.Changeset.force_change_attribute(:disposition, disposition)
    |> Ash.Changeset.after_action(fn changeset, result ->
      note = Ash.Changeset.get_argument(changeset, :note)
      details = Ash.Changeset.get_argument(changeset, :details) || %{}

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

  defp append_effect!(%{source_version_id: version_id}, audit, :retry, note, details, _actor)
       when is_binary(version_id) do
    BrusselsWtf.Ingestion.record_processing_run!(%{
      source_version_id: version_id,
      processor_name: "review-retry",
      processor_version: Map.get(details, "processor", "review-action-1"),
      config_hash: BrusselsWtf.Digest.sha256(audit.id),
      status: :queued,
      output: %{"review_action_id" => audit.id, "note" => note}
    })
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
end
