defmodule BrusselsWtfWeb.PublicationReaderTest do
  use BrusselsWtfWeb.ConnCase, async: false
  alias BrusselsWtf.Review.Actor

  setup do
    BrusselsWtf.Seeds.PublicTimeline.run!()
    :ok
  end

  test "coverage reports gaps without claiming archival replay is a fresh check", %{conn: conn} do
    for locale <- ~w(en fr nl) do
      html = conn |> get("/coverage?lang=#{locale}") |> html_response(200)
      assert html =~ "Ixelles"
      assert html =~ "Uccle"
      assert html =~ "Forest"
      assert html =~ "City of Brussels"
      refute html =~ "review_case"
      assert conn |> get("/about?lang=#{locale}") |> html_response(200) =~ "Rico Trevisan"
    end
  end

  test "item corrections stay private and cannot create ownership claims", %{conn: conn} do
    {:ok, page} = BrusselsWtf.Council.get_published_meeting_page("ixelles", "demo-ixelles")
    item = Enum.find(page.council_meeting.agenda_items, & &1.published?)
    config = Application.fetch_env!(:brussels_wtf, :suggestions)

    Application.put_env(
      :brussels_wtf,
      :suggestions,
      config
      |> Keyword.put(:enabled, true)
      |> Keyword.put(:rate_limit_secret, String.duplicate("test-correction-", 4))
    )

    on_exit(fn -> Application.put_env(:brussels_wtf, :suggestions, config) end)

    html = conn |> get("/meetings/ixelles/demo-ixelles?lang=en") |> html_response(200)
    assert html =~ "/items/#{item.id}/suggestions/correction"
    body = "Please verify this particular item against page 12 of the official source."

    attrs = %{
      kind: :correction,
      subject_type: :agenda_item,
      subject_reference: item.id,
      body: body,
      contact: "reader@example.test"
    }

    assert {:ok, :accepted} = BrusselsWtf.Suggestions.submit(attrs, client_address: "192.0.2.31")

    assert {:error, :invalid_submission} =
             BrusselsWtf.Suggestions.submit(%{attrs | kind: :ownership},
               client_address: "192.0.2.31"
             )

    reviewer = %Actor{id: "rico", role: :reviewer}
    [suggestion] = Ash.read!(BrusselsWtf.Review.Suggestion, actor: reviewer)
    assert suggestion.subject_id == item.id
    assert suggestion.body == body
    refute conn |> get("/meetings/ixelles/demo-ixelles?lang=en") |> html_response(200) =~ body
    refute html =~ "reader@example.test"
  end

  test "Brussels calendar boundary handles summer and winter time" do
    previous = BrusselsWtf.Clock.utc_now()
    on_exit(fn -> BrusselsWtf.Clock.Controlled.set(previous) end)

    for {instant, expected} <- [
          {~U[2026-07-01 22:30:00Z], ~D[2026-07-02]},
          {~U[2026-01-01 23:30:00Z], ~D[2026-01-02]}
        ] do
      BrusselsWtf.Clock.Controlled.set(instant)
      assert BrusselsWtfWeb.MeetingTime.today() == expected
      assert BrusselsWtfWeb.MeetingTime.group(:proposal, expected) == :coming
      assert BrusselsWtfWeb.MeetingTime.group(:proposal, Date.add(expected, -1)) == :awaiting
    end
  end
end
