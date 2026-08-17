defmodule BrusselsWtf.Ingestion.RetrievalObservation do
  @moduledoc "One attempted or successful check of a source locator."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Ingestion,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "retrieval_observations"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :source_locator_id,
        :source_version_id,
        :poll_run_id,
        :observed_at,
        :status,
        :http_status,
        :sha256,
        :final_url,
        :response_headers,
        :redirect_chain,
        :error_kind,
        :error_message
      ]
    end

    read :for_locator do
      argument :source_locator_id, :uuid, allow_nil?: false
      filter expr(source_locator_id == ^arg(:source_locator_id))
      prepare build(sort: [observed_at: :asc, inserted_at: :asc])
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :observed_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:success, :unchanged, :failure, :disappeared]
    end

    attribute :http_status, :integer, public?: true
    attribute :sha256, :string, public?: true
    attribute :final_url, :string, public?: true
    attribute :response_headers, :map, public?: true, default: %{}
    attribute :redirect_chain, {:array, :map}, public?: true, default: []
    attribute :error_kind, :string, public?: true
    attribute :error_message, :string, public?: true
    timestamps()
  end

  relationships do
    belongs_to :source_locator, BrusselsWtf.Ingestion.SourceLocator do
      allow_nil? false
      public? true
    end

    belongs_to :source_version, BrusselsWtf.Ingestion.SourceVersion do
      public? true
    end

    belongs_to :poll_run, BrusselsWtf.Ingestion.PollRun do
      allow_nil? false
      public? true
    end
  end
end
