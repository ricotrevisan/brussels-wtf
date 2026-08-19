defmodule BrusselsWtf.Ingestion do
  @moduledoc """
  Source acquisition: communes, locators, observations, and immutable versions.
  """

  use Ash.Domain, otp_app: :brussels_wtf

  resources do
    resource BrusselsWtf.Ingestion.Commune do
      define :create_commune, action: :create
      define :list_communes, action: :read
      define :get_commune, action: :read, get_by: [:id]
      define :get_commune_by_slug, action: :read, get_by: [:slug]
    end

    resource BrusselsWtf.Ingestion.PollRun do
      define :start_poll_run, action: :create
      define :get_poll_run, action: :read, get_by: [:id]
      define :list_poll_runs, action: :read
      define :mark_poll_run_running, action: :mark_running
      define :mark_poll_run_retrying, action: :mark_retrying
      define :mark_poll_run_dispatched, action: :mark_dispatched
      define :complete_poll_run, action: :complete
      define :fail_poll_run, action: :fail
    end

    resource BrusselsWtf.Ingestion.SourceLocator do
      define :get_locator, action: :read, get_by: [:id]
      define :upsert_locator, action: :upsert
      define :list_document_locators, action: :documents_for_commune, args: [:commune_id]
      define :list_locators, action: :for_commune, args: [:commune_id]
      define :list_due_locators, action: :due_for_fetch, args: [:now]
      define :schedule_locator_fetch, action: :schedule_fetch
    end

    resource BrusselsWtf.Ingestion.SourceRecord do
      define :get_source_record, action: :read, get_by: [:id]
      define :get_source_record_by_origin, action: :by_origin, args: [:commune_id, :origin_url]
      define :upsert_source_record, action: :upsert
      define :link_source_record_to_meeting, action: :link_meeting
      define :link_source_record_to_agenda_item, action: :link_agenda_item
      define :reclassify_source_record, action: :reclassify
    end

    resource BrusselsWtf.Ingestion.RetrievalObservation do
      define :record_observation, action: :record
      define :list_observations, action: :for_locator, args: [:source_locator_id]
    end

    resource BrusselsWtf.Ingestion.SourceVersion do
      define :get_source_version, action: :read, get_by: [:id]
      define :upsert_source_version, action: :upsert
    end

    resource BrusselsWtf.Ingestion.DerivedArtifact do
      define :get_derived_artifact, action: :read, get_by: [:id]
      define :upsert_derived_artifact, action: :upsert
    end

    resource BrusselsWtf.Ingestion.ProcessingAttempt do
      define :record_processing_attempt, action: :record
    end

    resource BrusselsWtf.Ingestion.ProcessingRunArtifact do
      define :link_processing_run_artifact, action: :link
    end

    resource BrusselsWtf.Ingestion.ProcessingRun do
      define :get_processing_run, action: :read, get_by: [:id]
      define :record_processing_run, action: :upsert
      define :create_review_processing_run, action: :review_retry
      define :complete_processing_run, action: :complete
    end
  end

  @type poll_target :: %{
          required(:type) => :commune | :meeting | :index | :locator,
          required(:id) => String.t()
        }

  @doc "Persists and enqueues an authenticated poll-now request."
  @spec request_poll_now!(poll_target(), actor: BrusselsWtf.Review.Actor.t()) ::
          BrusselsWtf.Ingestion.PollRun.t()
  def request_poll_now!(target, opts) when is_map(target) and is_list(opts) do
    actor = Keyword.fetch!(opts, :actor)
    request_poll!(target, :poll_now, actor, :current)
  end

  @doc "Persists and enqueues an explicit authenticated historical backfill."
  @spec request_backfill!(poll_target(), actor: BrusselsWtf.Review.Actor.t()) ::
          BrusselsWtf.Ingestion.PollRun.t()
  def request_backfill!(target, opts) when is_map(target) and is_list(opts) do
    actor = Keyword.fetch!(opts, :actor)
    request_poll!(target, :backfill, actor, :backfill)
  end

  @doc "Enqueues one fixed scheduled commune poll from cron."
  def request_scheduled_poll!(commune_slug, scope \\ :current) when is_binary(commune_slug) do
    commune = ensure_configured_commune!(commune_slug)
    target_type = if scope == :previous_year, do: :index, else: :commune

    request_poll!(
      %{type: target_type, id: commune.id},
      :scheduled,
      %{id: "system", role: :system},
      scope
    )
  end

  @doc false
  @spec poll_now(String.t()) :: :ok | {:error, term()}
  def poll_now(commune_slug) when is_binary(commune_slug) do
    if Application.get_env(:brussels_wtf, :allow_synthetic_seeds, false) do
      commune = get_commune_by_slug!(commune_slug)

      request_poll_now!(%{type: :commune, id: commune.id},
        actor: %BrusselsWtf.Review.Actor{id: "test-harness", role: :reviewer}
      )

      :ok
    else
      {:error, :reviewer_required}
    end
  end

  defp request_poll!(target, kind, actor, scope) do
    authorize_poll_request!(kind, actor)
    {target_type, target_id, commune, jobs} = resolve_poll_target!(target)
    check_key = "poll:#{Ecto.UUID.generate()}"
    now = BrusselsWtf.Clock.utc_now()

    poll_run =
      start_poll_run!(%{
        commune_id: commune.id,
        started_at: now,
        kind: kind,
        requester_id: actor.id,
        target_type: target_type,
        target_id: target_id,
        check_key: check_key,
        scope: scope,
        status: :queued
      })

    try do
      Enum.each(jobs, fn
        {:commune, commune_id} ->
          %{
            commune_id: commune_id,
            poll_run_id: poll_run.id,
            check_key: check_key,
            attempt: 1
          }
          |> BrusselsWtf.Workers.PollCommune.new()
          |> Oban.insert!()

        {:locator, locator_id} ->
          %{
            locator_id: locator_id,
            poll_run_id: poll_run.id,
            check_key: check_key,
            attempt: 1
          }
          |> BrusselsWtf.Workers.FetchLocator.new()
          |> Oban.insert!()
      end)

      if target_type == :meeting do
        mark_poll_run_dispatched!(poll_run, %{completed_at: BrusselsWtf.Clock.utc_now()})
      else
        poll_run
      end
    rescue
      error ->
        fail_poll_run!(poll_run, %{
          completed_at: BrusselsWtf.Clock.utc_now(),
          error_summary: "poll queue insertion failed"
        })

        reraise error, __STACKTRACE__
    end
  end

  defp resolve_poll_target!(%{type: type, id: id}) when type in [:commune, :index] do
    commune = get_commune!(id)
    {type, id, commune, [{:commune, commune.id}]}
  end

  defp resolve_poll_target!(%{type: :locator, id: id}) do
    locator = get_locator!(id)
    commune = get_commune!(locator.commune_id)
    {:locator, id, commune, [{:locator, locator.id}]}
  end

  defp resolve_poll_target!(%{type: :meeting, id: id}) do
    meeting = BrusselsWtf.Council.get_meeting!(id)
    commune = get_commune!(meeting.commune_id)

    jobs =
      commune.id
      |> list_document_locators!()
      |> Enum.filter(&(&1.meeting_identifier == meeting.municipal_identifier))
      |> Enum.map(&{:locator, &1.id})

    case jobs do
      [] ->
        raise Ash.Error.Query.NotFound,
          resource: BrusselsWtf.Ingestion.SourceLocator,
          primary_key: %{meeting_id: id}

      _jobs ->
        {:meeting, id, commune, jobs}
    end
  end

  defp ensure_configured_commune!(slug) do
    case get_commune_by_slug(slug) do
      {:ok, commune} ->
        commune

      _not_found ->
        configuration = BrusselsWtf.Communes.configuration!(slug)

        create_commune!(%{
          slug: slug,
          name: configuration.name,
          index_url: configuration.index_url
        })
    end
  end

  defp authorize_poll_request!(:scheduled, %{role: :system}), do: :ok
  defp authorize_poll_request!(_kind, %{role: :reviewer, id: id}) when is_binary(id), do: :ok
  defp authorize_poll_request!(_kind, _actor), do: raise(Ash.Error.Forbidden, errors: [])

  @doc "Returns actionable poll freshness and repeated-failure indicators."
  def poll_health(now \\ BrusselsWtf.Clock.utc_now()) do
    stale_after = Application.get_env(:brussels_wtf, :poll_stale_after_seconds, 12 * 60 * 60)
    recent_failure_window = 24 * 60 * 60
    runs = list_poll_runs!()

    stale_commune_ids =
      list_communes!()
      |> Enum.reject(fn commune ->
        Enum.any?(runs, fn run ->
          run.commune_id == commune.id and run.kind == :scheduled and
            run.status in [:dispatched, :completed] and
            match?(%DateTime{}, run.completed_at) and
            DateTime.diff(now, run.completed_at, :second) <= stale_after
        end)
      end)
      |> Enum.map(& &1.id)

    repeated_failure_targets =
      runs
      |> Enum.filter(fn run ->
        run.status == :failed and match?(%DateTime{}, run.completed_at) and
          DateTime.diff(now, run.completed_at, :second) <= recent_failure_window
      end)
      |> Enum.group_by(&{&1.commune_id, &1.target_type, &1.target_id})
      |> Enum.flat_map(fn {{commune_id, target_type, target_id}, failed_runs} ->
        if length(failed_runs) >= 2 do
          [
            %{
              commune_id: commune_id,
              target_type: target_type,
              target_id: target_id,
              failures: length(failed_runs)
            }
          ]
        else
          []
        end
      end)

    %{
      stale_commune_count: length(stale_commune_ids),
      stale_commune_ids: stale_commune_ids,
      repeated_failure_count: length(repeated_failure_targets),
      repeated_failure_targets: repeated_failure_targets
    }
  end

  @doc "Runs one locator check through the public ingestion boundary."
  def check_locator(locator_id, poll_run_id) do
    check_locator(locator_id, poll_run_id, "poll:#{poll_run_id}:locator:#{locator_id}")
  end

  def check_locator(locator_id, poll_run_id, check_key) when is_binary(check_key) do
    BrusselsWtf.Ingestion.Pipeline.retrieve(locator_id, poll_run_id, check_key)
  end

  @doc "Returns exact locator contexts and ordered observations for one authoritative origin."
  def locator_history!(commune_id, origin_url) when is_binary(origin_url) do
    commune_id
    |> list_locators!()
    |> Enum.filter(&(&1.url == origin_url))
    |> Enum.map(fn locator ->
      Ash.load!(locator, :observations)
      |> Map.update!(
        :observations,
        &Enum.sort_by(&1, fn observation ->
          {observation.observed_at, observation.inserted_at, observation.id}
        end)
      )
    end)
  end

  @doc "Returns immutable source history through Ash-backed domain reads."
  def source_history!(commune_id, origin_url) when is_binary(origin_url) do
    record = get_source_record_by_origin!(commune_id, origin_url)

    observations =
      commune_id
      |> list_locators!()
      |> Enum.filter(&(&1.url == origin_url))
      |> Enum.flat_map(&list_observations!(&1.id))
      |> Enum.sort_by(fn observation ->
        {
          DateTime.to_unix(observation.observed_at, :microsecond),
          DateTime.to_unix(observation.inserted_at, :microsecond),
          observation.id
        }
      end)

    versions =
      record.versions
      |> Ash.load!(:processing_runs)
      |> Enum.sort_by(& &1.first_retrieved_at, DateTime)

    %{
      source_record: record,
      versions: versions,
      observations: observations,
      processing_runs:
        versions
        |> Enum.flat_map(& &1.processing_runs)
        |> Enum.sort_by(& &1.inserted_at, DateTime)
    }
  end
end
