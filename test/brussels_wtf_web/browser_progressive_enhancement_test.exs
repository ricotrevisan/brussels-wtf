defmodule BrusselsWtfWeb.BrowserProgressiveEnhancementTest do
  use ExUnit.Case, async: true

  test "browser-local commune enhancement remains usable" do
    {output, status} =
      System.cmd("node", ["--test", "assets/test/reader_preferences_test.mjs"],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
