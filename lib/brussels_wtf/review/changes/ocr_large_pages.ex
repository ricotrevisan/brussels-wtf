defmodule BrusselsWtf.Review.Changes.OcrLargePages do
  @moduledoc false
  use Ash.Resource.Change
  alias BrusselsWtf.{Ingestion, Review}
  alias BrusselsWtf.Ingestion.LargePdfOcrRecovery, as: Recovery

  def change(changeset, _, context) do
    review_case = Ash.get!(Review.Case, changeset.data.id, authorize?: false)

    version =
      Ingestion.get_source_version!(Ash.Changeset.get_argument(changeset, :source_version_id))

    native = Ingestion.get_processing_run!(Ash.Changeset.get_argument(changeset, :native_run_id))
    pages = Ash.Changeset.get_argument(changeset, :original_pages)
    sha = Ash.Changeset.get_argument(changeset, :sha256)

    if version.sha256 == sha and Recovery.eligible_native?(native, review_case, version, pages) do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, :open)
      |> Ash.Changeset.force_change_attribute(:disposition, :retry_requested)
      |> Ash.Changeset.after_action(fn changeset, review_case ->
        metadata = Recovery.metadata()

        provenance = %{
          "processor_name" => metadata.ocr_processor_name,
          "processor_version" => metadata.ocr_processor_version,
          "config_hash" => metadata.config_hash,
          "tool_versions" => metadata.tool_versions
        }

        details =
          Map.merge(provenance, %{
            "operation" => "ocr_large_pages",
            "extraction_only" => true,
            "sha256" => sha,
            "source_version_id" => version.id,
            "native_run_id" => native.id,
            "original_pages" => pages
          })

        {audit, audit_notifications} =
          Review.record_review_action!(
            %{
              review_case_id: review_case.id,
              action: :retry,
              effect: :processing_generation,
              disposition: :retry_requested,
              note: Ash.Changeset.get_argument(changeset, :note),
              details: details
            },
            actor: context.actor,
            return_notifications?: true
          )

        {run, run_notifications} =
          Ingestion.record_processing_run!(
            %{
              source_version_id: version.id,
              generation_key: "review:#{audit.id}",
              processor_role: :ocr,
              processor_name: metadata.ocr_processor_name,
              processor_version: metadata.ocr_processor_version,
              config_hash: metadata.config_hash,
              tool_versions: metadata.tool_versions,
              status: :queued,
              output: %{},
              inputs:
                Map.merge(details, %{
                  "review_case_id" => review_case.id,
                  "review_action_id" => audit.id,
                  "source_sha256" => sha
                })
            },
            return_notifications?: true
          )

        {_, budget_notifications} =
          Ingestion.open_ocr_recovery_budget!(%{processing_run_id: run.id},
            return_notifications?: true
          )

        page_notifications =
          Enum.flat_map(pages, fn page ->
            {_, notifications} =
              Ingestion.record_processing_run!(
                %{
                  source_version_id: version.id,
                  generation_key: "#{run.generation_key}:page:#{page}",
                  processor_role: :ocr,
                  processor_name: run.processor_name,
                  processor_version: run.processor_version,
                  config_hash: run.config_hash,
                  tool_versions: run.tool_versions,
                  status: :queued,
                  output: %{},
                  inputs:
                    Map.merge(run.inputs, %{"parent_run_id" => run.id, "original_pages" => [page]})
                },
                return_notifications?: true
              )

            notifications
          end)

        %{processing_run_id: run.id} |> BrusselsWtf.Workers.OcrLargeSource.new() |> Oban.insert!()

        {:ok, Ash.Resource.set_metadata(review_case, %{large_ocr_run_id: run.id}),
         audit_notifications ++ run_notifications ++ budget_notifications ++ page_notifications}
      end)
    else
      Ash.Changeset.add_error(changeset,
        field: :native_run_id,
        message: "requires exact held native generation and only rejected original pages"
      )
    end
  end
end
