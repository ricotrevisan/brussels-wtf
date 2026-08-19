defmodule BrusselsWtf.ProcessRoleTest do
  use ExUnit.Case, async: true

  test "app and OCR roles cannot consume each other's work" do
    base = Application.fetch_env!(:brussels_wtf, Oban)
    app = BrusselsWtf.ProcessRole.oban(:app, base)
    ocr = BrusselsWtf.ProcessRole.oban(:ocr, base)

    refute Keyword.has_key?(app[:queues], :ocr)
    assert app[:plugins] != false
    assert ocr[:queues] == [ocr: 1]
    assert ocr[:plugins] == false

    assert BrusselsWtf.Application.oban_config(:app) == app
    assert BrusselsWtf.Application.oban_config(:ocr) == ocr
    assert Application.fetch_env!(:brussels_wtf, :automatic_transcription) == false
  end
end
