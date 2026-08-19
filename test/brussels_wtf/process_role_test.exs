defmodule BrusselsWtf.ProcessRoleTest do
  use ExUnit.Case, async: true

  test "app and OCR roles cannot consume each other's work" do
    app = BrusselsWtf.ProcessRole.oban(:app)
    ocr = BrusselsWtf.ProcessRole.oban(:ocr)

    refute Keyword.has_key?(app[:queues], :ocr)
    assert ocr[:queues] == [ocr: 1]
    assert ocr[:plugins] == false
    assert Application.fetch_env!(:brussels_wtf, :automatic_transcription) == false
  end
end
