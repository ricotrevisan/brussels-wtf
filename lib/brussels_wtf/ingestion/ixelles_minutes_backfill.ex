defmodule BrusselsWtf.Ingestion.IxellesMinutesBackfill do
  @moduledoc """
  Operator entry point: requeue retained Ixelles minutes through the current normalizer.

  `dry_run/1` reads the retained text through the exact normalization input and code and
  writes nothing. `requeue/1` queues only what a dry run reports as `:ready`, within the
  same bounded window. `receipt/1` compares that reading with the recorded and published
  state. Every point is accounted for as decided, non-votable, or unmatched.

  Output contains public meeting identifiers and printed point numbers only.
  """

  alias BrusselsWtf.{Council, Ingestion}
  alias BrusselsWtf.Ingestion.Pipeline

  @default_since ~D[2026-01-01]
  @commune "ixelles"

  @doc "Reports the bounded plan without writing anything."
  def dry_run(opts \\ []), do: opts |> plan() |> print("dry run: nothing written")

  @doc "Queues one normalization per `:ready` source version in the window."
  def requeue(opts \\ []) do
    entries =
      opts
      |> plan()
      |> Enum.map(fn
        %{status: :ready} = entry ->
          job = Pipeline.enqueue_automatic_normalization(entry.run, entry.origin_url)
          Map.put(entry, :queued, not job.conflict?)

        entry ->
          entry
      end)

    print(entries, "requeued")
  end

  @doc "Reports the reading next to what is now recorded and published."
  def receipt(opts \\ []) do
    entries = opts |> plan() |> Enum.map(&Map.merge(&1, recorded_state(&1)))

    print(entries, "receipt")
  end

  @doc "The minutes source versions in the window, each with its read-only preview."
  def plan(opts \\ []) do
    since = Keyword.get(opts, :since, @default_since)

    @commune
    |> locators(since)
    |> Enum.map(&entry/1)
    |> Enum.sort_by(&{&1.scheduled_on, &1.meeting_identifier})
  end

  defp locators(slug, since) do
    commune = Ingestion.get_commune_by_slug!(slug)

    commune.id
    |> Ingestion.list_document_locators!()
    |> Enum.filter(fn locator ->
      locator.role == :minutes and not is_nil(locator.scheduled_on) and
        Date.compare(locator.scheduled_on, since) != :lt
    end)
    |> Enum.uniq_by(& &1.url)
    |> Enum.map(&{commune, &1})
  end

  defp entry({commune, locator}) do
    base = %{
      meeting_identifier: locator.meeting_identifier,
      scheduled_on: locator.scheduled_on,
      origin_url: locator.url
    }

    case Ingestion.get_source_record_by_origin(commune.id, locator.url, not_found_error?: false) do
      {:ok, nil} -> Map.put(base, :status, :not_archived)
      {:ok, record} -> preview(base, record)
    end
  end

  defp preview(base, record) do
    with version when not is_nil(version) <- latest_version(record),
         run when not is_nil(run) <- latest_accepted_run(version) do
      # The worker discards a held run, so it must never be reported as ready.
      if Ingestion.LargePdfRecovery.held?(run),
        do: Map.put(base, :status, :extraction_only_hold),
        else: read(base, version, run)
    else
      nil -> Map.put(base, :status, :no_accepted_extraction)
    end
  end

  defp latest_version(record) do
    record
    |> Ash.load!(:versions)
    |> Map.fetch!(:versions)
    |> Enum.max_by(& &1.first_retrieved_at, DateTime, fn -> nil end)
  end

  defp latest_accepted_run(version) do
    version.id
    |> Ingestion.get_source_version!()
    |> Ash.load!(processing_runs: [:derived_artifacts])
    |> Map.fetch!(:processing_runs)
    |> Enum.filter(fn run ->
      run.processor_role in [:native_extraction, :ocr] and run.status == :succeeded and
        run.quality_measurements["accepted"] == true
    end)
    |> Enum.max_by(& &1.completed_at, DateTime, fn -> nil end)
  end

  defp read(base, version, run) do
    base = Map.merge(base, %{run: run, source_version_id: version.id})

    case BrusselsWtf.Processors.normalize(Pipeline.normalization_input(run)) do
      {:ok, %{"minutes_receipt" => receipt}} ->
        Map.merge(base, %{status: :ready, reading: receipt})

      {:ok, _recorded} ->
        Map.put(base, :status, :recorded_contract)

      {:error, {:normalization_ambiguity, details}} ->
        Map.merge(base, %{status: :ambiguous, reason: details["reason"] || details})

      {:error, reason} ->
        Map.merge(base, %{status: :unsupported, reason: reason})
    end
  end

  defp recorded_state(%{source_version_id: version_id, meeting_identifier: identifier}) do
    case Council.list_agenda_item_identities!(@commune, identifier) do
      [] ->
        %{recorded: 0, published: 0, revisions: 0}

      items ->
        loaded = Ash.load!(items, [:decisions, :council_meeting])

        decided =
          Enum.filter(loaded, fn item ->
            Enum.any?(item.decisions, &(&1.source_version_id == version_id))
          end)

        page = hd(loaded).council_meeting |> Ash.load!(:meeting_page) |> Map.fetch!(:meeting_page)

        %{
          recorded: length(decided),
          published:
            Enum.count(decided, &(&1.published? and &1.published_procedural_state == :decision)),
          revisions: page_revision_count(page)
        }
    end
  end

  defp recorded_state(_entry), do: %{}

  defp page_revision_count(nil), do: 0
  defp page_revision_count(page), do: length(Council.list_publication_revisions!(page.id))

  defp print(entries, label) do
    IO.puts("ixelles minutes #{label}: #{length(entries)} source records")
    Enum.each(entries, &IO.puts(line(&1)))
    entries
  end

  defp line(entry) do
    [
      "#{entry.meeting_identifier} #{entry.scheduled_on} #{entry.status}",
      reading_text(entry[:reading]),
      entry[:reason] && "reason=#{inspect(entry.reason)}",
      Map.has_key?(entry, :queued) && "queued=#{entry.queued}",
      Map.has_key?(entry, :recorded) &&
        "recorded=#{entry.recorded} published=#{entry.published} revisions=#{entry.revisions}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end

  defp reading_text(nil), do: nil

  defp reading_text(reading) do
    unmatched =
      Enum.map_join(reading["unmatched"], ",", &"#{&1["identifier"]}:#{&1["reason"]}")

    "points=#{reading["points"]} decided=#{reading["decided"]} " <>
      "non_votable=#{reading["non_votable"]} minutes_only=#{reading["minutes_only"]} " <>
      "contested=#{reading["contested"]} unmatched=#{length(reading["unmatched"])}" <>
      if(unmatched == "", do: "", else: " [#{unmatched}]")
  end
end
