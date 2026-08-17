defmodule BrusselsWtf.Seeds.PublicTimelineTest do
  use BrusselsWtf.DataCase, async: false

  test "synthetic public seeds fail closed when the environment does not opt in" do
    previous = Application.get_env(:brussels_wtf, :allow_synthetic_seeds)
    on_exit(fn -> Application.put_env(:brussels_wtf, :allow_synthetic_seeds, previous) end)
    Application.put_env(:brussels_wtf, :allow_synthetic_seeds, false)

    assert_raise RuntimeError, ~r/synthetic public timeline seeds are disabled/, fn ->
      BrusselsWtf.Seeds.PublicTimeline.run!()
    end
  end
end
