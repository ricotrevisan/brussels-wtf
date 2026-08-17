defmodule BrusselsWtf.Ingestion.Pipeline do
  @moduledoc """
  Named domain steps invoked by Oban workers.

  Workers own I/O orchestration. These functions persist through Ash actions
  and enqueue the next queue.
  """

  require Ash.Query

  alias BrusselsWtf.Council
  alias BrusselsWtf.Ingestion
  alias BrusselsWtf.Workers

  @extract_processor "extract"
  @processor_version "skeletal-1"
  @config_hash "none"

  @spec discover_and_enqueue(Ecto.UUID.t()) :: :ok
  def discover_and_enqueue(commune_id) do
    commune = Ingestion.get_commune!(commune_id)
    adapter = BrusselsWtf.Communes.adapter!(commune.slug)

    poll_run =
      Ingestion.start_poll_run!(%{
        commune_id: commune.id,
        started_at: BrusselsWtf.Clock.utc_now(),
        kind: :poll_now
      })

    {:ok, %{status: 200, body: body}} = BrusselsWtf.HTTP.get(commune.index_url)
    {:ok, locators} = adapter.discover(body, commune.index_url)

    Enum.each(locators, fn locator ->
      stored =
        Ingestion.upsert_locator!(%{
          commune_id: commune.id,
          url: locator.url,
          parent_index_url: locator.parent_index_url,
          meeting_identifier: locator.meeting_identifier,
          role: locator.role,
          discovered_at: BrusselsWtf.Clock.utc_now()
        })

      %{locator_id: stored.id, poll_run_id: poll_run.id}
      |> Workers.FetchLocator.new()
      |> Oban.insert!()
    end)

    :ok
  end

  @spec retrieve(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def retrieve(locator_id, poll_run_id) do
    locator = Ingestion.get_locator!(locator_id)
    now = BrusselsWtf.Clock.utc_now()

    case BrusselsWtf.HTTP.get(locator.url) do
      {:ok, %{status: 200, body: body, final_url: final_url}} ->
        sha256 = BrusselsWtf.Digest.sha256(body)
        {:ok, object_key} = BrusselsWtf.Archive.put(sha256, body)

        source_record =
          Ingestion.upsert_source_record!(%{
            commune_id: locator.commune_id,
            origin_url: locator.url,
            role: locator.role,
            original_language: :fr
          })

        version =
          Ingestion.upsert_source_version!(%{
            source_record_id: source_record.id,
            sha256: sha256,
            byte_size: byte_size(body),
            media_type: media_type(locator.url),
            object_key: object_key,
            first_retrieved_at: now
          })

        already_processed? = processed?(version.id)

        Ingestion.record_observation!(%{
          source_locator_id: locator.id,
          poll_run_id: poll_run_id,
          observed_at: now,
          status: if(already_processed?, do: :unchanged, else: :success),
          http_status: 200,
          sha256: sha256,
          final_url: final_url
        })

        unless already_processed? do
          %{source_version_id: version.id}
          |> Workers.ExtractSource.new()
          |> Oban.insert!()
        end

        :ok

      {:ok, %{status: status, final_url: final_url}} ->
        Ingestion.record_observation!(%{
          source_locator_id: locator.id,
          poll_run_id: poll_run_id,
          observed_at: now,
          status: :failure,
          http_status: status,
          final_url: final_url
        })

        :ok

      {:error, _reason} ->
        Ingestion.record_observation!(%{
          source_locator_id: locator.id,
          poll_run_id: poll_run_id,
          observed_at: now,
          status: :failure
        })

        :ok
    end
  end

  @spec extract(Ecto.UUID.t()) :: :ok
  def extract(source_version_id) do
    version =
      Ash.load!(Ingestion.get_source_version!(source_version_id), :source_record)

    {:ok, bytes} = BrusselsWtf.Archive.get(version.object_key)
    {:ok, extracted} = BrusselsWtf.Processors.extract(%{sha256: version.sha256}, bytes)

    run =
      Ingestion.record_processing_run!(%{
        source_version_id: version.id,
        processor_name: @extract_processor,
        processor_version: @processor_version,
        config_hash: @config_hash,
        status: :succeeded,
        output: Map.put(extracted, "sha256", version.sha256)
      })

    %{processing_run_id: run.id, locator_url: version.source_record.origin_url}
    |> Workers.NormalizeSource.new()
    |> Oban.insert!()

    :ok
  end

  @spec normalize(Ecto.UUID.t(), String.t()) :: :ok
  def normalize(processing_run_id, citation_url) do
    run =
      Ash.load!(Ingestion.get_processing_run!(processing_run_id),
        source_version: [source_record: [:commune]]
      )

    source_record = run.source_version.source_record
    {:ok, normalized} = BrusselsWtf.Processors.normalize(run.output)
    {:ok, locales} = BrusselsWtf.Processors.generate_locales(run.output)

    meeting =
      Council.upsert_meeting!(%{
        commune_id: source_record.commune_id,
        municipal_identifier: normalized["meeting_identifier"],
        scheduled_on: Date.from_iso8601!(normalized["scheduled_on"])
      })

    items = List.wrap(normalized["items"])

    Enum.each(items, fn item ->
      Council.upsert_agenda_item!(%{
        council_meeting_id: meeting.id,
        item_number: item["item_number"],
        source_wording: item["source_wording"],
        procedural_state: procedural_state(item["kind"])
      })
    end)

    first = List.first(items) || %{}
    procedural_state = procedural_state(first["kind"])

    page =
      Council.upsert_meeting_page!(%{
        council_meeting_id: meeting.id,
        citation_url: citation_url,
        procedural_state: procedural_state
      })

    Enum.each(locales, fn {locale, variant} ->
      Council.upsert_locale_variant!(%{
        meeting_page_id: page.id,
        locale: to_string(locale),
        title: variant["title"],
        summary: variant["summary"],
        provenance: provenance_for(locale)
      })
    end)

    %{meeting_id: meeting.id}
    |> Workers.PublishMeeting.new()
    |> Oban.insert!()

    :ok
  end

  @spec publish(Ecto.UUID.t()) :: :ok
  def publish(meeting_id) do
    meeting = Ash.load!(Council.get_meeting!(meeting_id), :meeting_page)
    page = meeting.meeting_page
    locales = Council.list_locale_variants!(page.id)
    have = MapSet.new(Enum.map(locales, & &1.locale))

    if MapSet.equal?(have, MapSet.new(["fr", "nl", "en"])) do
      Council.publish_meeting_page!(page)
    end

    :ok
  end

  defp processed?(source_version_id) do
    BrusselsWtf.Ingestion.ProcessingRun
    |> Ash.Query.filter(source_version_id == ^source_version_id)
    |> Ash.read_one!()
    |> is_struct()
  end

  defp media_type(url) do
    cond do
      String.ends_with?(url, ".pdf") -> "application/pdf"
      String.ends_with?(url, ".html") -> "text/html"
      true -> "text/plain"
    end
  end

  defp provenance_for(locale) when locale in ["nl", :nl, "en", :en],
    do: [:ai_generated, :machine_translated]

  defp provenance_for(_locale), do: [:ai_generated]

  defp procedural_state("decision"), do: :decision
  defp procedural_state("unknown"), do: :unknown
  defp procedural_state(_), do: :proposal
end
