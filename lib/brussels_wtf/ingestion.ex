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
    end

    resource BrusselsWtf.Ingestion.SourceRecord do
      define :upsert_source_record, action: :upsert
    end

    resource BrusselsWtf.Ingestion.RetrievalObservation do
      define :record_observation, action: :create
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

    %{commune_id: commune.id}
    |> BrusselsWtf.Workers.PollCommune.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
