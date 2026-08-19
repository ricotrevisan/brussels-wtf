defmodule BrusselsWtf.Ingestion.ProcessingFailure do
  @moduledoc "Shared terminal classification for processor failures."

  @deterministic [
    :repeated_quality_failure,
    :unsupported_media,
    :invalid_content,
    :corruption,
    :resource_limit,
    :authentication_failure
  ]

  def classify(:repeated_quality_failure), do: :repeated_quality_failure
  def classify({:quality_failure, _details}), do: :repeated_quality_failure
  def classify(:unsupported_media), do: :unsupported_media
  def classify({:unsupported_media, _details}), do: :unsupported_media
  def classify(:invalid_content), do: :invalid_content
  def classify({:invalid_content, _details}), do: :invalid_content
  def classify({:archived_hash_mismatch, _expected, _actual}), do: :corruption
  def classify({:invalid_pdf, _details}), do: :invalid_content
  def classify({:oversized_pdf, _details}), do: :resource_limit
  def classify({:ocr_limit, _details}), do: :resource_limit
  def classify({:processor_limit, _details}), do: :resource_limit
  def classify({:invalid_ocr_pages, _details}), do: :invalid_content
  def classify({:processor_unavailable, _details}), do: :processor_unavailable
  def classify({:authentication_failure, _details}), do: :authentication_failure
  def classify({:ocr_failed, _details}), do: :processing_failure
  def classify({:processor_failed, _details}), do: :processing_failure
  def classify(_reason), do: :processing_failure

  def deterministic?(classification), do: classification in @deterministic
  def terminal(:processing_failure), do: :processor_failure
  def terminal(classification), do: classification
end
