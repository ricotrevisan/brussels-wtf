defmodule BrusselsWtf.Workers.PollCommune do
  @moduledoc false

  use Oban.Worker,
    queue: :poll,
    max_attempts: 1,
    unique: [period: :infinity, fields: [:worker, :args], states: :all]

  alias BrusselsWtf.Ingestion

  @impl true
  def perform(%Oban.Job{
        args: %{
          "commune_slug" => commune_slug,
          "kind" => "scheduled",
          "scope" => "previous-year"
        }
      }) do
    Ingestion.request_scheduled_poll!(commune_slug, :previous_year)
    :ok
  end

  def perform(%Oban.Job{args: %{"commune_slug" => commune_slug, "kind" => "scheduled"}}) do
    Ingestion.request_scheduled_poll!(commune_slug)
    :ok
  end

  def perform(%Oban.Job{
        args:
          %{
            "commune_id" => commune_id,
            "poll_run_id" => poll_run_id,
            "check_key" => base_check_key
          } = args
      }) do
    started_monotonic = System.monotonic_time()
    attempt = Map.get(args, "attempt", 1)
    check_key = "#{base_check_key}:index:attempt:#{attempt}"
    run = Ingestion.get_poll_run!(poll_run_id)
    Ingestion.mark_poll_run_running!(run)

    outcome =
      case BrusselsWtf.Ingestion.Pipeline.discover_and_enqueue(
             commune_id,
             poll_run_id,
             check_key,
             attempt
           ) do
        {:retry, delay_seconds} ->
          enqueue_retry(commune_id, poll_run_id, base_check_key, attempt + 1, delay_seconds)

        {:review, classification} ->
          terminal_review(commune_id, poll_run_id, base_check_key, classification, attempt)

        result when result in [:ok, :complete, :disappeared] ->
          Ingestion.complete_poll_run!(Ingestion.get_poll_run!(poll_run_id), %{
            completed_at: BrusselsWtf.Clock.utc_now()
          })

          :completed
      end

    BrusselsWtf.Ingestion.Observability.poll_stopped(
      Ingestion.get_poll_run!(poll_run_id),
      outcome,
      started_monotonic
    )

    :ok
  end

  defp enqueue_retry(commune_id, poll_run_id, check_key, attempt, delay_seconds) do
    %{
      commune_id: commune_id,
      poll_run_id: poll_run_id,
      check_key: check_key,
      attempt: attempt
    }
    |> __MODULE__.new(schedule_in: delay_seconds)
    |> Oban.insert!()

    Ingestion.mark_poll_run_retrying!(Ingestion.get_poll_run!(poll_run_id))

    BrusselsWtf.Ingestion.Observability.retry_scheduled(
      %{poll_run_id: poll_run_id, commune_id: commune_id, attempt: attempt},
      delay_seconds
    )

    :retrying
  end

  defp terminal_review(commune_id, poll_run_id, generation, classification, attempt) do
    index_locator =
      commune_id
      |> Ingestion.list_locators!()
      |> Enum.find(&(&1.role == :index))

    review_case =
      BrusselsWtf.Review.open_review_case!(%{
        kind: :acquisition,
        commune_id: commune_id,
        affected_record_id: index_locator.id,
        affected_record_type: "source_locator",
        processing_generation: generation,
        urgency: :high,
        summary: "Commune index polling stopped after #{classification} and requires review",
        diagnostics: %{
          "classification" => Atom.to_string(classification),
          "attempt" => attempt
        }
      })

    Ingestion.fail_poll_run!(Ingestion.get_poll_run!(poll_run_id), %{
      completed_at: BrusselsWtf.Clock.utc_now(),
      error_summary: "Commune index polling stopped after #{classification}"
    })

    BrusselsWtf.Ingestion.Observability.review_case_created(%{
      poll_run_id: poll_run_id,
      commune_id: commune_id,
      review_case_id: review_case.id,
      classification: classification
    })

    :failed
  end
end
