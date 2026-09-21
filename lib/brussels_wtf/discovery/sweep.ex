defmodule BrusselsWtf.Discovery.Sweep do
  @moduledoc false
  require Ash.Query
  alias BrusselsWtf.{Clock, Discovery, Ingestion, Repo}
  alias BrusselsWtf.Discovery.{Input, Job, SweepEvent, SweepReport, SweepRun, SweepState}

  @communes ~w(ixelles uccle forest city-of-brussels)
  @limits [max_runs: 4, max_jobs: 8, max_unfinished: 64, daily_jobs: 500]

  def enable(opts) do
    with :ok <- Discovery.reviewer(opts), :ok <- limits(opts) do
      Discovery.serialized(fn ->
        control = state()
        attrs = opts |> Keyword.take(Keyword.keys(@limits)) |> Map.new()

        control =
          advance(control, Map.merge(attrs, %{enabled: true, enabled_by: opts[:actor].id}))

        record("enable", opts[:actor].id, %{control: safe_control(control)})
        safe_control(control)
      end)
    end
  end

  defp limits(opts) do
    if Enum.all?(opts, fn
         {:actor, _} ->
           true

         {key, value} ->
           is_integer(value) and value >= 1 and value <= Keyword.get(@limits, key, 0)
       end),
       do: :ok,
       else: {:error, :invalid_sweep_limits}
  end

  # Called only under Discovery's shared writer lock. Manual batches remain
  # available before automatic opt-in, but never bypass a hold or an allowance.
  def state do
    case read(SweepState) do
      [control] ->
        control

      [] ->
        control = create(SweepState, :initialize, %{})

        if count(Job |> Ash.Query.filter(state == :paused)) > 0,
          do: advance(control, %{hold: "legacy_pause"}),
          else: control
    end
  end

  def hold(reason, actor_id) do
    control = advance(state(), %{hold: reason})

    record("pause", actor_id, %{
      hold: reason,
      revision: control.revision,
      affected_jobs: unfinished()
    })
  end

  def release(actor_id) do
    control = advance(state(), %{hold: nil})

    record("resume", actor_id, %{
      revision: control.revision,
      affected_jobs: count(Job |> Ash.Query.filter(state == :paused))
    })
  end

  def paused?, do: not is_nil(state().hold)

  def admit!(attrs, batch_id, actor_id) do
    control = current_day(state())
    existing = Enum.map(attrs, &existing_job/1)
    new_count = Enum.count(existing, &is_nil/1)

    cond do
      control.hold -> Repo.rollback(:discovery_paused)
      new_count > max(control.daily_jobs - control.day_used, 0) -> Repo.rollback(:daily_budget)
      new_count > max(control.max_unfinished - unfinished(), 0) -> Repo.rollback(:backpressure)
      true -> :ok
    end

    jobs =
      Enum.zip(attrs, existing)
      |> Enum.map(fn {input, job} ->
        job ||
          create(
            Job,
            :enqueue,
            Map.merge(input, %{batch_ids: [batch_id], requested_by: actor_id})
          )
      end)
      |> Enum.map(fn job ->
        if batch_id in job.batch_ids,
          do: job,
          else:
            job
            |> Ash.Changeset.for_update(:transition, %{batch_ids: job.batch_ids ++ [batch_id]})
            |> Ash.update!(authorize?: false)
      end)

    advance(control, %{day_used: control.day_used + new_count})
    {jobs, new_count}
  end

  def tick do
    # The plan is just database metadata. Archive reads happen after its short
    # transaction; a changed revision invalidates the entire prepared plan.
    with {:ok, plan} <- Discovery.serialized(&plan/0) do
      case plan do
        %{reason: _} = report ->
          {:ok, report}

        %{control: control, runs: runs} ->
          prepared =
            Enum.map(runs, fn {commune, run, progress} ->
              input =
                if progress && progress.status == :admitted,
                  do: :admitted,
                  else: prepare(run.id, if(progress, do: progress.next_chunk, else: 0))

              {commune, run, progress, input}
            end)

          Discovery.serialized(fn -> commit(control, prepared) end)
      end
    end
  end

  defp prepare(id, offset) do
    Input.prepare(id, offset)
  rescue
    _ -> {:error, :preparation_failed}
  catch
    :exit, _ -> {:error, :preparation_failed}
  end

  defp plan do
    control = current_day(state())

    case stop_reason(control) do
      nil ->
        communes =
          Enum.drop(@communes, control.commune_offset) ++
            Enum.take(@communes, control.commune_offset)

        runs =
          communes
          |> Stream.flat_map(fn commune ->
            case next_run(commune, control.cursors[commune]) do
              nil -> []
              run -> [{commune, run, progress(run.id)}]
            end
          end)
          |> Enum.take(control.max_runs)

        %{control: control, runs: runs}

      reason ->
        tick_receipt(%{reason: reason})
    end
  end

  defp stop_reason(control) do
    cond do
      control.hold -> :paused
      not control.enabled -> :disabled
      control.day_used >= control.daily_jobs -> :daily_budget
      unfinished() >= control.max_unfinished -> :backpressure
      true -> nil
    end
  end

  defp next_run(commune, cursor) do
    query =
      Ingestion.ProcessingRun
      |> Ash.Query.filter(
        status == :succeeded and processor_role in [:native_extraction, :ocr] and
          source_version.source_record.commune.slug == ^commune
      )
      |> Ash.Query.select([:id])
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(1)

    # Repeating bounded cycles also sees old queued IDs completed behind the
    # cursor. Excluded runs are reconsidered after context/artifact corrections.
    after_cursor = if cursor, do: Ash.Query.filter(query, id > ^cursor), else: query
    List.first(Ash.read!(after_cursor)) || List.first(Ash.read!(query))
  end

  defp progress(id) do
    SweepRun
    |> Ash.Query.filter(extraction_run_id == ^id and contract == ^Input.contract())
    |> read()
    |> List.first()
  end

  defp commit(expected, prepared) do
    control = current_day(state())

    cond do
      control.revision != expected.revision -> tick_receipt(%{reason: :stale_plan})
      reason = stop_reason(control) -> tick_receipt(%{reason: reason})
      true -> commit_runs(control, prepared)
    end
  end

  defp commit_runs(control, prepared) do
    capacity =
      Enum.min([
        control.max_jobs,
        control.daily_jobs - control.day_used,
        control.max_unfinished - unfinished()
      ])

    batch_id = Ash.UUID.generate()

    {report, cursors, _remaining} =
      Enum.reduce(
        prepared,
        {%{examined: 0, eligible: 0, excluded: 0, new_jobs: 0, existing_jobs: 0, runs: []},
         control.cursors, capacity},
        fn {commune, run, progress, input}, {report, cursors, remaining} ->
          {receipt, used} =
            record_run(commune, run.id, progress, input, remaining, batch_id, control.enabled_by)

          report = %{
            report
            | examined: report.examined + 1,
              eligible: report.eligible + if(receipt.status == :excluded, do: 0, else: 1),
              excluded: report.excluded + if(receipt.status == :excluded, do: 1, else: 0),
              new_jobs: report.new_jobs + used,
              existing_jobs: report.existing_jobs + receipt.existing_jobs,
              runs: report.runs ++ [receipt]
          }

          {report, Map.put(cursors, commune, run.id), remaining - used}
        end
      )

    # admit! may have advanced the budget/revision. Cursor and all jobs still
    # commit in this same transaction under the same global serialization lock.
    advance(state(), %{cursors: cursors, commune_offset: rem(control.commune_offset + 1, 4)})
    tick_receipt(Map.put(report, :batch_id, batch_id))
  end

  defp record_run(commune, id, progress, input, capacity, batch_id, actor_id) do
    base = %{
      extraction_run_id: id,
      contract: Input.contract(),
      commune: commune,
      next_chunk: if(progress, do: progress.next_chunk, else: 0),
      total_chunks: if(progress, do: progress.total_chunks),
      measurements: if(progress, do: progress.measurements, else: %{}),
      examinations: if(progress, do: progress.examinations + 1, else: 1),
      new_jobs: if(progress, do: progress.new_jobs, else: 0),
      skip_reason: nil
    }

    {attrs, used, existing} =
      case input do
        :admitted ->
          {Map.put(base, :status, :admitted), 0, 0}

        {:error, reason} ->
          {Map.merge(base, %{status: :excluded, skip_reason: to_string(reason)}), 0, 0}

        {:ok, %{jobs: [], measurements: measurements}} ->
          {Map.merge(base, %{
             status: :excluded,
             skip_reason: "no_eligible_lines",
             total_chunks: measurements["total_chunks"],
             measurements: measurements
           }), 0, 0}

        {:ok, input} ->
          # Include existing jobs for free; stop at the first unadmitted chunk so
          # no absolute offset is skipped when the remaining allowance is small.
          {selected, _} =
            Enum.reduce_while(input.jobs, {[], capacity}, fn attrs, {selected, left} ->
              exists = not is_nil(existing_job(attrs))

              if exists or left > 0,
                do: {:cont, {[attrs | selected], left - if(exists, do: 0, else: 1)}},
                else: {:halt, {selected, left}}
            end)

          selected = Enum.reverse(selected)
          {jobs, used} = admit!(selected, batch_id, actor_id)
          next_chunk = base.next_chunk + length(jobs)
          total = input.measurements["total_chunks"]

          {Map.merge(base, %{
             status: if(next_chunk == total, do: :admitted, else: :eligible),
             next_chunk: next_chunk,
             total_chunks: total,
             measurements: input.measurements,
             new_jobs: base.new_jobs + used
           }), used, length(jobs) - used}
      end

    create(SweepRun, :record, attrs)

    {%{
       run_id: id,
       status: attrs.status,
       skip_reason: attrs.skip_reason,
       new_jobs: used,
       existing_jobs: existing,
       next_chunk: attrs.next_chunk
     }, used}
  end

  def status(opts) do
    with :ok <- Discovery.reviewer(opts), :ok <- SweepReport.validate(opts) do
      Discovery.serialized(fn ->
        report = SweepReport.build(safe_control(state()), opts)
        record("status", opts[:actor].id, %{counts: report.counts})
        report
      end)
    end
  end

  def record(operation, actor, report) do
    create(SweepEvent, :record, %{
      operation: operation,
      actor_id: actor,
      report:
        Map.merge(
          %{
            new_jobs: 0,
            excluded: 0,
            terminal_failures: count(Job |> Ash.Query.filter(state == :failed))
          },
          report
        )
    })
  end

  defp tick_receipt(report) do
    report =
      Map.merge(%{examined: 0, eligible: 0, excluded: 0, new_jobs: 0, existing_jobs: 0}, report)

    record("tick", "scheduler", report)
    report
  end

  defp current_day(control) do
    day = Clock.utc_now() |> DateTime.to_date()

    if is_nil(control.budget_day) or Date.compare(day, control.budget_day) == :gt,
      do: advance(control, %{budget_day: day, day_used: 0}),
      else: control
  end

  defp existing_job(attrs) do
    Job
    |> Ash.Query.filter(
      extraction_run_id == ^attrs.extraction_run_id and chunk == ^attrs.chunk and
        contract == ^attrs.contract
    )
    |> read()
    |> List.first()
  end

  defp unfinished, do: count(Job |> Ash.Query.filter(state in [:queued, :leased, :paused]))

  defp safe_control(control),
    do:
      Map.take(control, [
        :enabled,
        :hold,
        :enabled_by,
        :revision,
        :cursors,
        :commune_offset,
        :max_runs,
        :max_jobs,
        :max_unfinished,
        :daily_jobs,
        :budget_day,
        :day_used
      ])

  defp read(query), do: Ash.read!(query, authorize?: false)
  defp count(query), do: Ash.count!(query, authorize?: false)

  defp create(resource, action, attrs),
    do: resource |> Ash.Changeset.for_create(action, attrs) |> Ash.create!(authorize?: false)

  defp advance(control, attrs),
    do:
      control
      |> Ash.Changeset.for_update(:advance, Map.put(attrs, :revision, control.revision + 1))
      |> Ash.update!(authorize?: false)
end
