defmodule BrusselsWtf.Ingestion.ProcessingFailure do
  @moduledoc "Shared terminal classification for processor failures."

  @deterministic [:repeated_quality_failure, :unsupported_media, :invalid_content, :corruption]

  def classify(:repeated_quality_failure), do: :repeated_quality_failure
  def classify({:quality_failure, _details}), do: :repeated_quality_failure
  def classify(:unsupported_media), do: :unsupported_media
  def classify({:unsupported_media, _details}), do: :unsupported_media
  def classify(:invalid_content), do: :invalid_content
  def classify({:invalid_content, _details}), do: :invalid_content
  def classify({:archived_hash_mismatch, _expected, _actual}), do: :corruption
  def classify(_reason), do: :processing_failure

  def deterministic?(classification), do: classification in @deterministic
  def terminal(:processing_failure), do: :repeated_quality_failure
  def terminal(classification), do: classification
end
