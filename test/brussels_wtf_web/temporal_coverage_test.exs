defmodule BrusselsWtfWeb.TemporalCoverageTest do
  use BrusselsWtfWeb.ConnCase, async: false

  setup do
    previous = BrusselsWtf.Clock.utc_now()
    on_exit(fn -> BrusselsWtf.Clock.Controlled.set(previous) end)
    BrusselsWtf.Seeds.PublicTimeline.run!()
    :ok
  end

  test "past proposals are separated from upcoming meetings and final decisions", %{conn: conn} do
    BrusselsWtf.Clock.Controlled.set(~U[2027-01-01 12:00:00Z])
    html = conn |> get("/?lang=en") |> html_response(200)
    document = LazyHTML.from_document(html)
    assert Enum.count(document["#coming-up ~ div article"]) == 0
    assert Enum.count(document[~s(section[aria-labelledby="awaiting-outcome"] article)]) > 0
    assert html =~ "What they decided"
    assert html =~ "Awaiting documented outcome"
  end

  test "calendar passage never changes the published decision state", %{conn: conn} do
    BrusselsWtf.Clock.Controlled.set(~U[2027-01-01 12:00:00Z])
    html = conn |> get("/meetings/ixelles/demo-ixelles?lang=en") |> html_response(200)
    assert html =~ "The meeting date has passed"
    assert html =~ "Outcome unknown"
    refute html =~ "Decision: approved"
  end
end
