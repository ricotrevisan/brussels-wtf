defmodule BrusselsWtf.Council.CoverageRun do
  @moduledoc "One immutable versioned generation or translation run for a meeting page."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "coverage_runs"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :meeting_page_id,
        :parent_run_id,
        :operation,
        :locale,
        :input_hash,
        :output_hash,
        :processor_name,
        :processor_version,
        :config_hash,
        :provider_category,
        :model,
        :method,
        :status,
        :input,
        :output,
        :usage,
        :duration_ms,
        :failure_details
      ]
    end

    read :for_page do
      argument :meeting_page_id, :uuid, allow_nil?: false
      filter expr(meeting_page_id == ^arg(:meeting_page_id))
      prepare build(sort: [inserted_at: :asc, locale: :asc])
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :operation, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:canonical_generation, :translation]
    end

    attribute :locale, :string do
      allow_nil? false
      public? true
      constraints match: ~r/^(fr|nl|en)$/
    end

    attribute :input_hash, :string, allow_nil?: false, public?: true
    attribute :output_hash, :string, allow_nil?: false, public?: true
    attribute :processor_name, :string, allow_nil?: false, public?: true
    attribute :processor_version, :string, allow_nil?: false, public?: true
    attribute :config_hash, :string, allow_nil?: false, public?: true
    attribute :provider_category, :string, allow_nil?: false, public?: true
    attribute :model, :string, public?: true

    attribute :method, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:ai_generation, :machine_translation, :deterministic]
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:succeeded, :failed]
    end

    attribute :input, :map, allow_nil?: false, public?: true
    attribute :output, :map, allow_nil?: false, public?: true
    attribute :usage, :map, allow_nil?: false, public?: true, default: %{}
    attribute :duration_ms, :integer, allow_nil?: false, public?: true, default: 0
    attribute :failure_details, :map, allow_nil?: false, public?: true, default: %{}
    timestamps()
  end

  relationships do
    belongs_to :meeting_page, BrusselsWtf.Council.MeetingPage,
      allow_nil?: false,
      public?: true

    belongs_to :parent_run, __MODULE__, public?: true
    has_many :translations, __MODULE__, destination_attribute: :parent_run_id
  end
end
