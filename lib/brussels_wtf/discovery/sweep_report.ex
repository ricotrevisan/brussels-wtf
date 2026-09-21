defmodule BrusselsWtf.Discovery.SweepReport do
  @moduledoc false
  require Ash.Query
  alias BrusselsWtf.Identity
  alias BrusselsWtf.Discovery.{Job, SweepEvent, SweepRun}

  def validate(opts) do
    if Enum.all?([:cursor, :failure_cursor, :event_cursor], fn key ->
         is_nil(opts[key]) or match?({:ok, _}, Ecto.UUID.cast(opts[key]))
       end), do: :ok, else: {:error, :invalid_cursor}
  end

  def build(control, opts) do
    {runs, next_cursor} =
      page(SweepRun, opts[:cursor], [
        :id,
        :extraction_run_id,
        :commune,
        :status,
        :next_chunk,
        :total_chunks,
        :skip_reason,
        :measurements,
        :examinations,
        :new_jobs
      ])

    {failures, failure_cursor} =
      page(Job |> Ash.Query.filter(state == :failed), opts[:failure_cursor], [
        :id,
        :extraction_run_id,
        :chunk,
        :failure_reason,
        :attempts
      ])

    {events, event_cursor} =
      page(
        SweepEvent,
        opts[:event_cursor],
        [
          :id,
          :operation,
          :actor_id,
          :report,
          :inserted_at
        ],
        :desc
      )

    mentions = Identity.Mention |> Ash.Query.filter(contains(occurrence_key, "discovery:"))
    occurrences = Ash.count!(mentions)

    unique_names =
      Enum.sum(
        for kind <- [:person, :organization] do
          mentions |> Ash.Query.filter(kind == ^kind) |> Ash.count!(field: :text, uniq?: true)
        end
      )

    counts =
      Map.new([:queued, :leased, :paused, :completed, :failed], fn status ->
        {status, count(Job |> Ash.Query.filter(state == ^status))}
      end)

    counts =
      Map.merge(counts, %{
        examined: count(SweepRun),
        examinations: Ash.sum!(SweepRun, :examinations, authorize?: false) || 0,
        eligible: count(SweepRun |> Ash.Query.filter(status in [:eligible, :admitted])),
        excluded: count(SweepRun |> Ash.Query.filter(status == :excluded)),
        fully_admitted: count(SweepRun |> Ash.Query.filter(status == :admitted)),
        mention_occurrences: occurrences,
        unique_mention_names: unique_names,
        repeated_mention_names: occurrences - unique_names
      })

    %{
      control: control,
      counts: counts,
      runs: runs,
      next_cursor: next_cursor,
      failures: failures,
      failure_cursor: failure_cursor,
      events: events,
      event_cursor: event_cursor
    }
  end

  defp page(query, cursor, fields, direction \\ :asc) do
    query =
      query |> Ash.Query.select(fields) |> Ash.Query.sort(id: direction) |> Ash.Query.limit(101)

    query =
      case {cursor, direction} do
        {nil, _} -> query
        {id, :asc} -> Ash.Query.filter(query, id > ^id)
        {id, :desc} -> Ash.Query.filter(query, id < ^id)
      end

    rows = Ash.read!(query, authorize?: false)
    page = rows |> Enum.take(100) |> Enum.map(&Map.take(&1, fields))
    {page, if(length(rows) > 100, do: List.last(page).id)}
  end

  defp count(query), do: Ash.count!(query, authorize?: false)
end
