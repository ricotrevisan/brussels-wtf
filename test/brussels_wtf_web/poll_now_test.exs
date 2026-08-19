defmodule BrusselsWtfWeb.PollNowTest do
  use BrusselsWtfWeb.ConnCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Review.Actor

  setup %{conn: conn} do
    BrusselsWtf.Clock.Controlled.set(~U[2026-08-20 12:00:00Z])

    commune =
      Ingestion.create_commune!(%{
        slug: "ixelles",
        name: "Ixelles",
        index_url: "https://example.test/index"
      })

    locator =
      Ingestion.upsert_locator!(%{
        commune_id: commune.id,
        url: "https://example.test/agenda.pdf",
        parent_index_url: commune.index_url,
        meeting_identifier: "268",
        scheduled_on: ~D[2026-08-30],
        role: :agenda,
        language: :fr,
        discovered_at: ~U[2026-08-20 10:00:00Z],
        next_fetch_at: ~U[2026-08-20 18:00:00Z]
      })

    meeting =
      BrusselsWtf.Council.upsert_meeting!(%{
        commune_id: commune.id,
        municipal_identifier: "268",
        scheduled_on: ~D[2026-08-30]
      })

    actor = %Actor{id: "rico", role: :reviewer}
    reviewer_conn = conn |> init_test_session(%{}) |> BrusselsWtfWeb.ReviewAuth.log_in(actor)
    {:ok, commune: commune, locator: locator, meeting: meeting, reviewer_conn: reviewer_conn}
  end

  test "anonymous poll-now requests are rejected", %{conn: conn, commune: commune} do
    response =
      post(conn, ~p"/review/polls", %{
        "operation" => "poll-now",
        "target_type" => "commune",
        "target_id" => commune.id
      })

    assert redirected_to(response) == ~p"/review/login"
    assert Ingestion.list_poll_runs!() == []
  end

  test "a reviewer can request an audited commune poll", %{
    reviewer_conn: conn,
    commune: commune
  } do
    response =
      post(conn, ~p"/review/polls", %{
        "operation" => "poll-now",
        "target_type" => "commune",
        "target_id" => commune.id
      })

    assert redirected_to(response) == ~p"/review"

    assert [
             %{
               kind: :poll_now,
               requester_id: "rico",
               target_type: :commune,
               target_id: target_id,
               status: :queued
             } = poll_run
           ] = Ingestion.list_poll_runs!()

    assert target_id == commune.id

    assert_enqueued(
      worker: BrusselsWtf.Workers.PollCommune,
      args: %{poll_run_id: poll_run.id, commune_id: commune.id}
    )
  end

  test "index, meeting, and explicit backfill targets retain their typed audit", %{
    reviewer_conn: conn,
    commune: commune,
    meeting: meeting,
    locator: locator
  } do
    post(conn, ~p"/review/polls", %{
      "operation" => "poll-now",
      "target_type" => "index",
      "target_id" => commune.id
    })

    post(conn, ~p"/review/polls", %{
      "operation" => "poll-now",
      "target_type" => "meeting",
      "target_id" => meeting.id
    })

    post(conn, ~p"/review/polls", %{
      "operation" => "backfill",
      "target_type" => "commune",
      "target_id" => commune.id
    })

    runs = Ingestion.list_poll_runs!()
    backfill = Enum.find(runs, &(&1.kind == :backfill))
    index = Enum.find(runs, &(&1.target_type == :index))
    meeting_run = Enum.find(runs, &(&1.target_type == :meeting))

    assert %{kind: :backfill, target_type: :commune, requester_id: "rico"} = backfill
    assert %{kind: :poll_now, target_type: :index} = index
    assert %{kind: :poll_now, target_type: :meeting} = meeting_run

    assert_enqueued(
      worker: BrusselsWtf.Workers.FetchLocator,
      args: %{locator_id: locator.id, poll_run_id: meeting_run.id}
    )
  end

  test "the review inbox exposes a CSRF-protected operational polling form", %{
    reviewer_conn: conn
  } do
    document = conn |> get(~p"/review") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.attribute(document["form[action='/review/polls']"], "method") == ["post"]

    assert LazyHTML.attribute(
             document["form[action='/review/polls'] input[name='_csrf_token']"],
             "value"
           ) != []
  end

  test "a locator poll-now targets only that locator and preserves its schedule", %{
    reviewer_conn: conn,
    locator: locator
  } do
    response =
      post(conn, ~p"/review/polls", %{
        "operation" => "poll-now",
        "target_type" => "locator",
        "target_id" => locator.id
      })

    assert redirected_to(response) == ~p"/review"
    assert [poll_run] = Ingestion.list_poll_runs!()
    assert poll_run.target_type == :locator
    assert poll_run.requester_id == "rico"

    assert_enqueued(
      worker: BrusselsWtf.Workers.FetchLocator,
      args: %{locator_id: locator.id, poll_run_id: poll_run.id}
    )

    assert DateTime.compare(
             Ingestion.get_locator!(locator.id).next_fetch_at,
             locator.next_fetch_at
           ) ==
             :eq
  end

  test "poll operations reject a request without a CSRF token", %{
    reviewer_conn: conn,
    commune: commune
  } do
    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> then(&%{&1 | private: Map.delete(&1.private, :plug_skip_csrf_protection)})
      |> post(~p"/review/polls", %{
        "operation" => "poll-now",
        "target_type" => "commune",
        "target_id" => commune.id
      })
    end
  end

  test "invalid poll targets return a safe validation response", %{reviewer_conn: conn} do
    response =
      post(conn, ~p"/review/polls", %{
        "operation" => "poll-now",
        "target_type" => "locator",
        "target_id" => "not-a-valid-id"
      })

    assert response(response, 422) == "Invalid poll target"
    assert Ingestion.list_poll_runs!() == []
  end
end
