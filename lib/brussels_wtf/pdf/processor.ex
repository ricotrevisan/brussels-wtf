defmodule BrusselsWtf.PDF.Processor do
  @moduledoc "Replaceable native-PDF and bounded-OCR executable boundary."

  @type result :: {:ok, map()} | {:error, term()}
  @callback native(map(), binary()) :: result()
  @callback ocr(map(), binary(), [pos_integer()]) :: result()
  @callback metadata() :: map()

  def native(meta, bytes), do: impl().native(meta, bytes)
  def ocr(meta, bytes, pages), do: impl().ocr(meta, bytes, pages)
  def metadata, do: impl().metadata()

  def metadata(%{ocr_profile: :scanned_declaration}) do
    metadata = metadata()
    hash = BrusselsWtf.Digest.sha256(metadata.config_hash <> ":force-ocr:pagesegmode-6")
    %{metadata | config_hash: "sha256:" <> hash}
  end

  def metadata(_), do: metadata()

  defp impl, do: Application.fetch_env!(:brussels_wtf, :pdf_processor)
end
