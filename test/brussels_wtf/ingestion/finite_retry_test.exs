defmodule BrusselsWtf.Ingestion.FiniteRetryTest do
  use BrusselsWtf.DataCase, async: false
  use Oban.Testing, repo: BrusselsWtf.Repo

  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Review
  alias BrusselsWtf.Review.Actor
  alias BrusselsWtf.Workers.FetchLocator

  setup do
    BrusselsWtf.HTTP.Stub.reset()
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
        url: "https://example.test/transient.pdf",
        parent_index_url: commune.index_url,
        meeting_identifier: "268",
        scheduled_on: ~D[2026-08-30],
        role: :agenda,
        language: :fr,
        discovered_at: ~U[2026-08-20 10:00:00Z],
        next_fetch_at: ~U[2026-08-20 18:00:00Z]
      })

    actor = %Actor{id: "rico", role: :reviewer}
    run = Ingestion.request_poll_now!(%{type: :locator, id: locator.id}, actor: actor)
    BrusselsWtf.HTTP.Stub.put_error(locator.url, :timeout)
    {:ok, locator: locator, run: run, actor: actor}
  end

  test "six retries retain seven observations and converge on one review case", %{
    locator: locator,
    run: run,
    actor: actor
  } do
    for attempt <- 1..6 do
      assert :ok =
               perform_job(FetchLocator, %{
                 locator_id: locator.id,
                 poll_run_id: run.id,
                 check_key: run.check_key,
                 attempt: attempt
               })

      assert_enqueued(
        worker: FetchLocator,
        args: %{
          locator_id: locator.id,
          poll_run_id: run.id,
          check_key: run.check_key,
          attempt: attempt + 1
        }
      )
    end

    assert :ok =
             perform_job(FetchLocator, %{
               locator_id: locator.id,
               poll_run_id: run.id,
               check_key: run.check_key,
               attempt: 7
             })

    assert Enum.map(Ingestion.list_observations!(locator.id), & &1.check_key) ==
             Enum.map(1..7, &"#{run.check_key}:locator:#{locator.id}:attempt:#{&1}")

    assert [review_case] = Review.list_review_cases!(%{kind: :acquisition}, actor: actor)
    assert review_case.affected_record_id == locator.id
    assert review_case.processing_generation == run.check_key
    assert review_case.summary =~ "retries exhausted"
    assert Ingestion.get_poll_run!(run.id).status == :failed

    assert :ok =
             perform_job(FetchLocator, %{
               locator_id: locator.id,
               poll_run_id: run.id,
               check_key: run.check_key,
               attempt: 7
             })

    assert length(Ingestion.list_observations!(locator.id)) == 7
    assert length(Review.list_review_cases!(%{kind: :acquisition}, actor: actor)) == 1
  end

  test "deterministic acquisition failures stop without transport retries", %{
    locator: locator,
    run: run,
    actor: actor
  } do
    BrusselsWtf.HTTP.Stub.put(locator.url, %{status: 415, body: "unsupported"})

    assert :ok =
             perform_job(FetchLocator, %{
               locator_id: locator.id,
               poll_run_id: run.id,
               check_key: run.check_key,
               attempt: 1
             })

    assert [%{http_status: 415, error_kind: "unsupported_media"}] =
             Ingestion.list_observations!(locator.id)

    assert [review_case] = Review.list_review_cases!(%{kind: :acquisition}, actor: actor)
    assert review_case.summary =~ "unsupported media"

    refute_enqueued(
      worker: FetchLocator,
      args: %{locator_id: locator.id, poll_run_id: run.id, attempt: 2}
    )
  end
end
