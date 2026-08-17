defmodule BrusselsWtf.Ingestion.ProcessingRun do
  @moduledoc """
  One execution of a named processor against a source version.
  """

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Ingestion,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "processing_runs"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :upsert do
      primary? true

      accept [
        :source_version_id,
        :processor_name,
        :processor_version,
        :config_hash,
        :status,
        :output
      ]

      upsert? true
      upsert_identity :unique_processing
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :processor_name, :string do
      allow_nil? false
      public? true
    end

    attribute :processor_version, :string do
      allow_nil? false
      public? true
    end

    attribute :config_hash, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:succeeded, :failed]
    end

    attribute :output, :map, public?: true

    timestamps()
  end

  relationships do
    belongs_to :source_version, BrusselsWtf.Ingestion.SourceVersion do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_processing, [
      :source_version_id,
      :processor_name,
      :processor_version,
      :config_hash
    ]
  end
end
