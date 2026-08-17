defmodule BrusselsWtf.Ingestion.RetrievalObservation do
  @moduledoc """
  One attempted or successful check of a source locator.
  """

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

    create :create do
      primary? true

      accept [
        :source_locator_id,
        :poll_run_id,
        :observed_at,
        :status,
        :http_status,
        :sha256,
        :final_url
      ]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :observed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:success, :unchanged, :failure, :disappeared]
    end

    attribute :http_status, :integer, public?: true
    attribute :sha256, :string, public?: true
    attribute :final_url, :string, public?: true

    timestamps()
  end

  relationships do
    belongs_to :source_locator, BrusselsWtf.Ingestion.SourceLocator do
      allow_nil? false
      public? true
    end

    belongs_to :poll_run, BrusselsWtf.Ingestion.PollRun do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_locator_poll, [:source_locator_id, :poll_run_id]
  end
end
