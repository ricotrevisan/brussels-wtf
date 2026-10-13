defmodule BrusselsWtf.Review.Changes.ExtractLargeNative do
  @moduledoc false
  use Ash.Resource.Change
  alias BrusselsWtf.{Ingestion, Review}
  alias BrusselsWtf.Ingestion.LargePdfRecovery

  @impl true
  def change(changeset, _opts, context) do
    review_case = Ash.get!(Review.Case, changeset.data.id, authorize?: false)

    version =
      Ingestion.get_source_version!(Ash.Changeset.get_argument(changeset, :source_version_id))

    changeset =
      cond do
        not LargePdfRecovery.eligible?(review_case, version) ->
          Ash.Changeset.add_error(changeset,
            field: :source_version_id,
            message: "requires an open oversized supporting PDF deferral"
          )

        version.sha256 != Ash.Changeset.get_argument(changeset, :sha256) ->
          Ash.Changeset.add_error(changeset,
            field: :sha256,
            message: "must match the immutable source"
          )

        true ->
          changeset
      end

    changeset
    |> Ash.Changeset.force_change_attribute(:status, :open)
    |> Ash.Changeset.force_change_attribute(:disposition, :retry_requested)
    |> Ash.Changeset.after_action(fn changeset, review_case ->
      metadata = LargePdfRecovery.metadata()
      sha256 = Ash.Changeset.get_argument(changeset, :sha256)
      version_id = Ash.Changeset.get_argument(changeset, :source_version_id)

      {audit, audit_notifications} =
        Review.record_review_action!(
          %{
            review_case_id: review_case.id,
            action: :retry,
            effect: :processing_generation,
            disposition: :retry_requested,
            note: Ash.Changeset.get_argument(changeset, :note),
            details: %{
              "operation" => "extract_large_native",
              "sha256" => sha256,
              "source_version_id" => version_id,
              "extraction_only" => true,
              "processor_name" => metadata.native_processor_name,
              "processor_version" => metadata.native_processor_version,
              "config_hash" => metadata.config_hash
            }
          },
          actor: context.actor,
          return_notifications?: true
        )

      {run, run_notifications} =
        Ingestion.record_processing_run!(
          %{
            source_version_id: version_id,
            generation_key: "review:#{audit.id}",
            processor_name: metadata.native_processor_name,
            processor_version: metadata.native_processor_version,
            config_hash: metadata.config_hash,
            processor_role: :native_extraction,
            status: :queued,
            tool_versions: metadata.tool_versions,
            inputs: %{
              "extraction_only" => true,
              "operation" => "extract_large_native",
              "source_sha256" => sha256,
              "review_case_id" => review_case.id,
              "review_action_id" => audit.id
            },
            output: %{}
          },
          return_notifications?: true
        )

      %{processing_run_id: run.id}
      |> BrusselsWtf.Workers.ExtractLargeSource.new()
      |> Oban.insert!()

      {:ok, Ash.Resource.set_metadata(review_case, %{large_processing_run_id: run.id}),
       audit_notifications ++ run_notifications}
    end)
  end
end
