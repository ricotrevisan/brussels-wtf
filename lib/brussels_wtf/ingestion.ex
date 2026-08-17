defmodule BrusselsWtf.Ingestion do
  @moduledoc """
  Source acquisition: communes, locators, observations, and immutable versions.
  """

  use Ash.Domain, otp_app: :brussels_wtf

  resources do
    resource BrusselsWtf.Ingestion.Commune do
      define :create_commune, action: :create
      define :get_commune, action: :read, get_by: [:id]
      define :get_commune_by_slug, action: :read, get_by: [:slug]
    end

    resource BrusselsWtf.Ingestion.PollRun do
      define :start_poll_run, action: :create
    end

    resource BrusselsWtf.Ingestion.SourceLocator do
      define :get_locator, action: :read, get_by: [:id]
      define :upsert_locator, action: :upsert
      define :list_document_locators, action: :documents_for_commune, args: [:commune_id]
      define :list_locators, action: :for_commune, args: [:commune_id]
    end

    resource BrusselsWtf.Ingestion.SourceRecord do
      define :get_source_record_by_origin, action: :by_origin, args: [:commune_id, :origin_url]
      define :upsert_source_record, action: :upsert
      define :link_source_record_to_meeting, action: :link_meeting
    end

    resource BrusselsWtf.Ingestion.RetrievalObservation do
      define :record_observation, action: :record
      define :list_observations, action: :for_locator, args: [:source_locator_id]
    end

    resource BrusselsWtf.Ingestion.SourceVersion do
      define :get_source_version, action: :read, get_by: [:id]
      define :upsert_source_version, action: :upsert
    end

    resource BrusselsWtf.Ingestion.ProcessingRun do
      define :get_processing_run, action: :read, get_by: [:id]
      define :record_processing_run, action: :upsert
    end
  end

  @spec poll_now(String.t()) :: :ok | {:error, term()}
  def poll_now(commune_slug) when is_binary(commune_slug) do
    commune = get_commune_by_slug!(commune_slug)

    %{commune_id: commune.id, check_key: "poll-now:#{Ecto.UUID.generate()}"}
    |> BrusselsWtf.Workers.PollCommune.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Runs one locator check through the public ingestion boundary."
  def check_locator(locator_id, poll_run_id) do
    check_locator(locator_id, poll_run_id, "poll:#{poll_run_id}:locator:#{locator_id}")
  end

  def check_locator(locator_id, poll_run_id, check_key) when is_binary(check_key) do
    BrusselsWtf.Ingestion.Pipeline.retrieve(locator_id, poll_run_id, check_key)
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
