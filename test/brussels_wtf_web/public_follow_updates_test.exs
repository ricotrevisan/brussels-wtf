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
      post(conn, "/feed/updates?lang=nl", %{targets: [%{type: "commune", id: "ixelles"}]})

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
      %{type: "commune", id: "missing"}
    ]

    assert %{"updates" => []} =
             json_response(post(conn, "/feed/updates", %{targets: malformed}), 200)

    duplicate = List.duplicate(%{type: "commune", id: "ixelles"}, 100)

    assert %{"updates" => [_]} =
             json_response(post(conn, "/feed/updates", %{targets: duplicate}), 200)

    oversized = for n <- 1..101, do: %{type: "dossier", id: "missing-#{n}"}

    assert %{"updates" => []} =
             json_response(post(conn, "/feed/updates", %{targets: oversized}), 200)

    assert %{"updates" => []} = json_response(post(conn, "/feed/updates", %{targets: nil}), 200)
  end
end
