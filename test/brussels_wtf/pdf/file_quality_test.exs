defmodule BrusselsWtf.PDF.FileQualityTest do
  use ExUnit.Case, async: true
  alias BrusselsWtf.PDF.{FileQuality, Quality}
  @limits %{max_output_bytes: 67_108_864, max_page_bytes: 262_144, max_pages: 500}

  test "bounded page assessment rejects invalid UTF8 and byte budgets before Quality" do
    path =
      Path.join(System.tmp_dir!(), "file-quality-budget-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(path) end)
    File.write!(path, <<255, 12>>)
    assert {:error, {:invalid_pdf, :invalid_utf8}} = FileQuality.assess(path, 1, @limits)
    File.write!(path, "123456789\f")

    assert {:error, {:processor_limit, :page_text_bytes}} =
             FileQuality.assess(path, 1, %{@limits | max_page_bytes: 8})

    assert {:error, {:processor_limit, :output_bytes}} =
             FileQuality.assess(path, 1, %{@limits | max_output_bytes: 8})

    # A multibyte codepoint straddles the 64KiB stream chunk, but not a page.
    text = String.duplicate("a", 65_535) <> "é\f"
    File.write!(path, text)
    assert {:ok, quality} = FileQuality.assess(path, 1, @limits)
    assert quality == Quality.assess([String.trim_trailing(text, "\f")])
  end

  test "quality deadline is finite and fails closed before reading text" do
    assert {:error, {:processor_limit, :wall_time}} =
             FileQuality.assess(
               "not-read",
               1,
               Map.put(@limits, :deadline_ms, System.monotonic_time(:millisecond) - 1)
             )
  end

  test "requires exactly positive original pages and terminal separators, never padding or truncating" do
    path = Path.join(System.tmp_dir!(), "file-quality-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    for {text, count} <- [
          {"", 0},
          {"page", 1},
          {"page\f", 2},
          {"page\fextra\f", 1},
          {"\f", 0},
          {"\ftrailing", 1}
        ] do
      File.write!(path, text)

      assert {:error, {:invalid_pdf, :page_completeness}} =
               FileQuality.assess(path, count, @limits)
    end

    File.write!(path, "first\f\fthird\f")
    assert {:ok, quality} = FileQuality.assess(path, 3, @limits)
    assert quality == Quality.assess(["first", "", "third"])
    assert quality["rejected_pages"] == [1, 2, 3]
  end
end
