defmodule BrusselsWtf.Ingestion.SourceLimits do
  @moduledoc "Separate acquisition and in-memory processing limits for source documents."

  @supporting_document_max_bytes 160 * 1_024 * 1_024

  def supporting_document_limit, do: @supporting_document_max_bytes

  def processing_limit do
    Application.fetch_env!(:brussels_wtf, :pdf_limits).max_input_bytes
  end

  def processing_allowed?(%{byte_size: size}), do: size <= processing_limit()

  def check_processing(version) do
    if processing_allowed?(version),
      do: :ok,
      else: {:error, {:oversized_pdf, %{byte_size: version.byte_size, limit: processing_limit()}}}
  end
end
