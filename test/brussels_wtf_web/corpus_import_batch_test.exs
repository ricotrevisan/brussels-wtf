defmodule BrusselsWtfWeb.CorpusImportBatchTest do
  use BrusselsWtfWeb.ConnCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Council
  alias BrusselsWtf.Review.Actor

  setup %{conn: conn} do
    actor = %Actor{id: "rico", role: :reviewer}
    reviewer_conn = conn |> init_test_session(%{}) |> BrusselsWtfWeb.ReviewAuth.log_in(actor)
    {:ok, reviewer_conn: reviewer_conn}
  end

  test "anonymous corpus import requests are rejected", %{conn: conn} do
    response = post(conn, ~p"/review/corpus-batches", %{"meeting_keys" => "ixelles-268"})
    assert redirected_to(response) == ~p"/review/login"
    assert Council.list_corpus_import_batches!() == []
  end

  test "a reviewer queues only an explicit sealed meeting allowlist", %{reviewer_conn: conn} do
    response = post(conn, ~p"/review/corpus-batches", %{"meeting_keys" => "ixelles-268"})
    assert redirected_to(response) == ~p"/review"

    assert [%{requester_id: "rico", meeting_keys: ["ixelles-268"]}] =
             Council.list_corpus_import_batches!()

    assert_enqueued worker: BrusselsWtf.Workers.ImportCorpusSource,
                    args: %{meeting_key: "ixelles-268"}
  end

  test "unknown selections fail without executable work", %{reviewer_conn: conn} do
    response = post(conn, ~p"/review/corpus-batches", %{"meeting_keys" => "unknown"})
    assert response.status == 422
    assert Council.list_corpus_import_batches!() == []
    refute_enqueued worker: BrusselsWtf.Workers.ImportCorpusSource
  end

  test "the review inbox exposes the corpus form and its sealed default allowlist", %{
    reviewer_conn: conn
  } do
    document = conn |> get(~p"/review") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.attribute(document["form[action='/review/corpus-batches']"], "method") == [
             "post"
           ]

    assert document |> LazyHTML.text() =~ "city-2026-06-08"
  end
end
