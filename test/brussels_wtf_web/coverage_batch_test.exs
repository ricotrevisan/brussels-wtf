defmodule BrusselsWtfWeb.CoverageBatchTest do
  use BrusselsWtfWeb.ConnCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Council
  alias BrusselsWtf.Review.Actor

  setup %{conn: conn} do
    previous = Application.fetch_env!(:brussels_wtf, :coverage_generation)
    on_exit(fn -> Application.put_env(:brussels_wtf, :coverage_generation, previous) end)

    Application.put_env(:brussels_wtf, :coverage_generation, %{
      mode: :recorded,
      backfill_enabled: true,
      backfill_max_batch_size: 10,
      monthly_budget_cents: nil
    })

    commune =
      BrusselsWtf.Ingestion.create_commune!(%{
        slug: "ixelles",
        name: "Ixelles",
        index_url: "https://example.test/index"
      })

    meeting =
      Council.upsert_meeting!(%{
        commune_id: commune.id,
        municipal_identifier: "268",
        scheduled_on: ~D[2026-08-20]
      })

    actor = %Actor{id: "rico", role: :reviewer}
    reviewer_conn = conn |> init_test_session(%{}) |> BrusselsWtfWeb.ReviewAuth.log_in(actor)
    {:ok, meeting: meeting, reviewer_conn: reviewer_conn}
  end

  test "anonymous coverage batch requests are rejected", %{conn: conn, meeting: meeting} do
    response = post(conn, ~p"/review/coverage-batches", %{"meeting_ids" => meeting.id})
    assert redirected_to(response) == ~p"/review/login"
    assert Council.list_coverage_batches!() == []
  end

  test "a reviewer queues an explicit meeting allowlist", %{
    reviewer_conn: conn,
    meeting: meeting
  } do
    response = post(conn, ~p"/review/coverage-batches", %{"meeting_ids" => meeting.id})
    assert redirected_to(response) == ~p"/review"

    assert [%{requester_id: "rico", meeting_ids: [meeting_id]}] =
             Council.list_coverage_batches!()

    assert meeting_id == meeting.id
  end

  test "the review inbox exposes the bounded coverage form", %{reviewer_conn: conn} do
    document = conn |> get(~p"/review") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.attribute(document["form[action='/review/coverage-batches']"], "method") == [
             "post"
           ]
  end
end
