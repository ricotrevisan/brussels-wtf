defmodule BrusselsWtf.Ingestion.LargePdfOcrRecovery do
  @moduledoc "Audited, page-selective OCR recovery. Extraction acceptance never releases publication."
  alias BrusselsWtf.{Ingestion, Review, Repo}
  alias BrusselsWtf.Ingestion.LargePdfRecovery
  require Ash.Query

  def execute(id, attempt), do: BrusselsWtf.Ingestion.LargePdfOcrExecution.execute(id, attempt)

  def processor,
    do:
      Application.get_env(:brussels_wtf, :large_pdf_ocr_processor, BrusselsWtf.PDF.FileProcessor)

  def metadata, do: processor().ocr_metadata()

  def request(entries, note, opts) do
    with true <- Keyword.keyword?(opts) and Keyword.keys(opts) == [:actor],
         true <- is_list(entries) and length(entries) in 1..5,
         true <- Enum.all?(entries, &valid_entry?/1),
         true <-
           length(Enum.uniq_by(entries, &Ecto.UUID.cast(&1.source_version_id))) == length(entries),
         true <- length(Enum.uniq_by(entries, &Ecto.UUID.cast(&1.case_id))) == length(entries),
         {:ok, results} <-
           Repo.transaction(
             fn ->
               Enum.map(entries, fn entry ->
                 review_case = Review.get_review_case!(entry.case_id, actor: opts[:actor])

                 {result, notifications} =
                   Review.ocr_large_pages!(
                     review_case,
                     Map.put(Map.drop(entry, [:case_id]), :note, note),
                     actor: opts[:actor],
                     return_notifications?: true
                   )

                 {Ingestion.get_processing_run!(result.__metadata__.large_ocr_run_id),
                  notifications}
               end)
             end,
             timeout: 5 * 120_000 + 30_000
           ) do
      Enum.each(results, fn {_, notifications} -> Ash.Notifier.notify(notifications) end)
      {:ok, Enum.map(results, &elem(&1, 0))}
    else
      _ -> {:error, :invalid_ocr_request}
    end
  rescue
    _ -> {:error, :invalid_ocr_request}
  end

  defp valid_entry?(entry) when is_map(entry) do
    Enum.sort(Map.keys(entry)) == [
      :case_id,
      :native_run_id,
      :original_pages,
      :sha256,
      :source_version_id
    ] and
      Enum.all?(
        [entry.case_id, entry.native_run_id, entry.source_version_id],
        &match?({:ok, _}, Ecto.UUID.cast(&1))
      ) and
      is_binary(entry.sha256) and Regex.match?(~r/\A[0-9a-f]{64}\z/, entry.sha256) and
      valid_pages?(entry.original_pages)
  end

  defp valid_entry?(_), do: false

  def valid_pages?(pages) do
    is_list(pages) and length(pages) in 1..32 and
      Enum.all?(pages, &(is_integer(&1) and &1 in 1..500)) and
      Enum.sort(Enum.uniq(pages)) == pages
  end

  @doc false
  def eligible_native?(native, review_case, version, pages) do
    audit =
      Ash.get!(Review.Action, native.inputs["review_action_id"], authorize?: false, error?: false)

    native = Ash.load!(native, :derived_artifacts)
    artifacts = Enum.filter(native.derived_artifacts, &(&1.output_kind == "native-text"))
    quality = native.quality_measurements
    measurements = quality["pages"]
    count = quality["page_count"]

    valid_quality =
      is_integer(count) and count in 1..500 and is_list(measurements) and
        length(measurements) == count and
        Enum.map(measurements, & &1["page"]) == Enum.to_list(1..count) and
        Enum.all?(measurements, &(&1["decision"] in ["accepted", "ocr_required"])) and
        quality["rejected_pages"] ==
          Enum.filter(measurements, &(&1["decision"] != "accepted")) |> Enum.map(& &1["page"]) and
        quality["accepted"] == Enum.all?(measurements, &(&1["decision"] == "accepted"))

    valid_artifact =
      case artifacts do
        [artifact] ->
          artifact.input_sha256 == version.sha256 and
            artifact.processor_name == native.processor_name and
            artifact.processor_version == native.processor_version and
            artifact.config_hash == native.config_hash and
            artifact.quality_measurements == quality

        _ ->
          false
      end

    LargePdfRecovery.eligible?(review_case, version) and valid_pages?(pages) and valid_quality and
      valid_artifact and
      native.source_version_id == version.id and native.processor_role == :native_extraction and
      native.status == :succeeded and native.inputs["extraction_only"] == true and
      native.inputs["operation"] == "extract_large_native" and
      native.inputs["source_sha256"] == version.sha256 and
      native.inputs["review_case_id"] == review_case.id and
      native.quality_measurements["page_count"] in 1..500 and
      Enum.all?(pages, &(&1 in native.quality_measurements["rejected_pages"])) and
      is_map(audit) and native.generation_key == "review:#{audit.id}" and
      audit.review_case_id == review_case.id and audit.action == :retry and
      audit.effect == :processing_generation and
      audit.details["operation"] == "extract_large_native" and
      audit.details["extraction_only"] == true and
      audit.details["source_version_id"] == version.id and
      audit.details["sha256"] == version.sha256 and
      audit.details["processor_name"] == native.processor_name and
      audit.details["processor_version"] == native.processor_version and
      audit.details["config_hash"] == native.config_hash
  rescue
    _ -> false
  end
end
