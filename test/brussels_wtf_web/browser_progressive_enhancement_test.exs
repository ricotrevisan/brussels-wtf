defmodule BrusselsWtfWeb.BrowserProgressiveEnhancementTest do
  use ExUnit.Case, async: true

  test "reading navigation preserves context and rejects unsafe return destinations" do
    {output, status} =
      System.cmd("node", ["--test", "assets/test/reader_navigation_test.mjs"],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  test "browser-local commune enhancement remains usable" do
    {output, status} =
      System.cmd("node", ["--test", "assets/test/reader_preferences_test.mjs"],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  test "browser-local snapshot import and personal feed remain usable" do
    {output, status} =
      System.cmd("node", ["--test", "assets/test/personal_feed_test.mjs"], stderr_to_stdout: true)

    assert status == 0, output
  end
end
