defmodule BrusselsWtf.Ingestion.PollRun do
  @moduledoc """
  One commune index check, scheduled or requested with poll-now.
  """

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Ingestion,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "poll_runs"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:commune_id, :started_at, :kind]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :started_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:scheduled, :poll_now]
    end

    timestamps()
  end

  relationships do
    belongs_to :commune, BrusselsWtf.Ingestion.Commune do
      allow_nil? false
      public? true
    end
  end
end
