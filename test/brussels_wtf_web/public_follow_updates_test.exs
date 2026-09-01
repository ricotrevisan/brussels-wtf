defmodule BrusselsWtfWeb.PublicFollowUpdatesTest do
  use BrusselsWtfWeb.ConnCase, async: false

  setup do
    Application.put_env(
      :brussels_wtf,
      :public_follow_update_provider,
      BrusselsWtf.Follow.PublicUpdates.Published
    )

    BrusselsWtf.Test.Harness.load("ixelles/proposal")
    assert :ok = BrusselsWtf.Ingestion.poll_now("ixelles")
    assert :ok = BrusselsWtf.Test.Harness.drain_pipeline()
    :ok
  end

  test "persisted published meeting emits a localized exact commune update", %{conn: conn} do
    response =
      post(conn, "/feed/updates?lang=nl", %{
        targets: [%{type: "commune", id: "ixelles", importedAt: imported_before_publication()}]
      })

    assert %{"updates" => [update]} = json_response(response, 200)
    assert update["eventType"] == "published_meeting_page"
    assert is_binary(update["revisionId"])
    assert update["url"] =~ ~r|^/meetings/ixelles/268\?lang=nl#revision-|
  end

  test "malformed duplicate and oversized anonymous inputs fail closed", %{conn: conn} do
    malformed = [
      nil,
      1,
      "x",
      %{},
      %{type: nil, id: []},
      %{type: "commune"},
      %{type: "commune", id: "missing", importedAt: imported_before_publication()}
    ]

    assert %{"updates" => []} =
             json_response(post(conn, "/feed/updates", %{targets: malformed}), 200)

    duplicate =
      List.duplicate(
        %{type: "commune", id: "ixelles", importedAt: imported_before_publication()},
        100
      )

    assert %{"updates" => [_]} =
             json_response(post(conn, "/feed/updates", %{targets: duplicate}), 200)

    oversized =
      for n <- 1..101,
          do: %{type: "dossier", id: "missing-#{n}", importedAt: imported_before_publication()}

    assert %{"updates" => []} =
             json_response(post(conn, "/feed/updates", %{targets: oversized}), 200)

    assert %{"updates" => []} = json_response(post(conn, "/feed/updates", %{targets: nil}), 200)
  end

  test "snapshot boundary excludes history and includes only a strictly later publication", %{
    conn: conn
  } do
    imported = Application.fetch_env!(:brussels_wtf, :clock).utc_now()
    target = %{type: "commune", id: "ixelles", importedAt: DateTime.to_iso8601(imported)}

    assert %{"updates" => []} =
             json_response(post(conn, "/feed/updates?lang=en", %{targets: [target]}), 200)

    page =
      BrusselsWtf.Council.MeetingPage
      |> Ash.Query.for_read(:published)
      |> Ash.read!(authorize?: false, domain: BrusselsWtf.Council)
      |> Enum.find(&(&1.current_revision_id != nil))

    later = DateTime.add(imported, 1, :second)
    BrusselsWtf.Clock.Controlled.set(later)

    event =
      BrusselsWtf.Council.PublicationEvent
      |> Ash.Changeset.for_create(:record, %{
        meeting_page_id: page.id,
        publication_revision_id: page.current_revision_id,
        event_type: :published,
        occurred_at: later,
        publication_metadata: %{},
        details: %{}
      })
      |> Ash.create!(authorize?: false, domain: BrusselsWtf.Council)

    assert %{"updates" => [update]} =
             json_response(post(conn, "/feed/updates?lang=en", %{targets: [target]}), 200)

    assert update["publicEventId"] == event.id
  end

  defp imported_before_publication do
    Application.fetch_env!(:brussels_wtf, :clock).utc_now()
    |> DateTime.add(-1, :second)
    |> DateTime.to_iso8601()
  end
end
