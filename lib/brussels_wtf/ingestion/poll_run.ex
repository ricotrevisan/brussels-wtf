defmodule BrusselsWtf.Ingestion.PollRun do
  @moduledoc """
  One scheduled, manually requested, or explicit backfill poll.

  The request is durable before Oban transport begins, so operator intent and
  requester identity survive queue retries and pruning.
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

      accept [
        :commune_id,
        :started_at,
        :kind,
        :requester_id,
        :target_type,
        :target_id,
        :check_key,
        :status
      ]
    end

    update :mark_running do
      accept []
      change set_attribute(:status, :running)
    end

    update :mark_retrying do
      accept []
      change set_attribute(:status, :retrying)
    end

    update :complete do
      accept [:completed_at]
      change set_attribute(:status, :completed)
    end

    update :fail do
      accept [:completed_at, :error_summary]
      change set_attribute(:status, :failed)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :started_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :completed_at, :utc_datetime_usec, public?: true

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:scheduled, :poll_now, :backfill]
    end

    attribute :requester_id, :string do
      allow_nil? false
      public? true
    end

    attribute :target_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:commune, :meeting, :index, :locator]
    end

    attribute :target_id, :string do
      allow_nil? false
      public? true
    end

    attribute :check_key, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :queued
      constraints one_of: [:queued, :running, :retrying, :completed, :failed]
    end

    attribute :error_summary, :string, public?: true
    timestamps()
  end

  relationships do
    belongs_to :commune, BrusselsWtf.Ingestion.Commune do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_check, [:check_key]
  end
end
