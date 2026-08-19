defmodule BrusselsWtf.Council.LocaleVariant do
  @moduledoc """
  One complete French, Dutch, or English representation of a meeting page.
  """

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Council,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "locale_variants"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :upsert do
      primary? true
      accept [:meeting_page_id, :coverage_run_id, :locale, :title, :summary, :provenance]
      upsert? true
      upsert_identity :unique_locale
    end

    read :for_page do
      argument :meeting_page_id, :uuid, allow_nil?: false
      filter expr(meeting_page_id == ^arg(:meeting_page_id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :locale, :string do
      allow_nil? false
      public? true
      constraints match: ~r/^(fr|nl|en)$/
    end

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :summary, :string do
      allow_nil? false
      public? true
    end

    attribute :provenance, {:array, :atom} do
      allow_nil? false
      public? true
      default []
      constraints items: [one_of: [:ai_generated, :machine_translated, :human_reviewed]]
    end

    timestamps()
  end

  relationships do
    belongs_to :coverage_run, BrusselsWtf.Council.CoverageRun, public?: true

    belongs_to :meeting_page, BrusselsWtf.Council.MeetingPage do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_locale, [:meeting_page_id, :locale]
  end
end
