defmodule BrusselsWtf.PDF.PopplerOcrTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.PDF.PopplerOcr

  test "rejects unsupported media before invoking production executables" do
    assert PopplerOcr.native(%{media_type: "image/png"}, "%PDF-fixture") ==
             {:error, {:unsupported_media, "image/png"}}
  end
end
