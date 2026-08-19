defmodule BrusselsWtf.Workers.FetchLocator do
  @moduledoc false

  use Oban.Worker,
    queue: :fetch,
    max_attempts: 1,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: :all
    ]

  alias BrusselsWtf.Ingestion

  @impl true
  def perform(
        %Oban.Job{
          args:
            %{
              "locator_id" => locator_id,
              "poll_run_id" => poll_run_id,
              "check_key" => base_check_key
            } = args
        } = job
      ) do
    started_monotonic = System.monotonic_time()
    attempt = Map.get(args, "attempt", 1)
    check_key = "#{base_check_key}:locator:#{locator_id}:attempt:#{attempt}"
    run = Ingestion.get_poll_run!(poll_run_id)

    if run.target_type == :locator do
      Ingestion.mark_poll_run_running!(run)
    end

    outcome =
      case BrusselsWtf.Ingestion.Pipeline.retrieve(
             locator_id,
             poll_run_id,
             check_key,
             attempt
           ) do
        {:retry, delay_seconds} ->
          enqueue_retry(locator_id, poll_run_id, base_check_key, attempt + 1, delay_seconds)

        {:review, classification} ->
          terminal_review(locator_id, poll_run_id, base_check_key, classification, attempt)

        result when result in [:ok, :complete, :disappeared] ->
          complete_attempt(locator_id, poll_run_id, result)
      end

    BrusselsWtf.Ingestion.Observability.poll_stopped(
      Ingestion.get_poll_run!(poll_run_id),
      outcome,
      started_monotonic,
      BrusselsWtf.Ingestion.Observability.queue_age(job)
    )

    :ok
  end

  defp enqueue_retry(locator_id, poll_run_id, check_key, attempt, delay_seconds) do
    %{
      locator_id: locator_id,
      poll_run_id: poll_run_id,
      check_key: check_key,
      attempt: attempt
    }
    |> __MODULE__.new(schedule_in: delay_seconds)
    |> Oban.insert!()

    run = Ingestion.get_poll_run!(poll_run_id)

    if run.target_type == :locator do
      Ingestion.mark_poll_run_retrying!(run)
    end

    BrusselsWtf.Ingestion.Observability.retry_scheduled(
      %{poll_run_id: poll_run_id, source_locator_id: locator_id, attempt: attempt},
      delay_seconds
    )

    :retrying
  end

  defp terminal_review(locator_id, poll_run_id, generation, classification, attempt) do
    locator = Ingestion.get_locator!(locator_id)
    run = Ingestion.get_poll_run!(poll_run_id)
    now = BrusselsWtf.Clock.utc_now()

    review_case =
      BrusselsWtf.Review.open_review_case!(%{
        kind: :acquisition,
        commune_id: locator.commune_id,
        affected_record_id: locator.id,
        affected_record_type: "source_locator",
        processing_generation: generation,
        urgency: :high,
        summary: review_summary(classification),
        diagnostics: %{
          "classification" => Atom.to_string(classification),
          "attempt" => attempt
        }
      })

    Ingestion.fail_poll_run!(run, %{
      completed_at: now,
      error_summary: review_summary(classification)
    })

    BrusselsWtf.Ingestion.Observability.review_case_created(%{
      poll_run_id: poll_run_id,
      source_locator_id: locator_id,
      review_case_id: review_case.id,
      classification: classification
    })

    :failed
  end

  defp complete_attempt(locator_id, poll_run_id, result) do
    run = Ingestion.get_poll_run!(poll_run_id)
    now = BrusselsWtf.Clock.utc_now()

    if run.kind == :scheduled do
      locator = Ingestion.get_locator!(locator_id)

      next_fetch_at =
        case result do
          :disappeared ->
            nil

          _other ->
            case BrusselsWtf.Ingestion.PollSchedule.next_fetch_at(locator, now) do
              :stop -> nil
              %DateTime{} = next -> next
            end
        end

      Ingestion.schedule_locator_fetch!(locator, %{
        next_fetch_at: next_fetch_at,
        last_checked_at: now
      })
    end

    if run.target_type == :locator do
      Ingestion.complete_poll_run!(run, %{completed_at: now})
    end

    :completed
  end

  defp review_summary(:transient_retries_exhausted),
    do: "Acquisition retries exhausted and require review"

  defp review_summary(:authentication_failure),
    do: "Authoritative source authentication failed and requires review"

  defp review_summary(:unsupported_media),
    do: "Authoritative source uses unsupported media and requires review"

  defp review_summary(:corruption),
    do: "Archived source verification failed and requires review"

  defp review_summary(classification),
    do: "Acquisition stopped after #{classification} and requires review"
end
