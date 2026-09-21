defmodule BrusselsWtf.CBE.Index.Entry do
  @moduledoc false
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.CBE.Index,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "cbe_index_entries"
    repo BrusselsWtf.Repo

    custom_indexes do
      index [:release_id, :file, :number, :ordinal]
    end
  end

  actions do
    defaults [:read]

    create :append do
      accept [:release_id, :file, :ordinal, :number, :data]
    end
  end

  attributes do
    attribute :release_id, :uuid, primary_key?: true, allow_nil?: false, sensitive?: true
    attribute :file, :string, primary_key?: true, allow_nil?: false
    attribute :ordinal, :integer, primary_key?: true, allow_nil?: false

    attribute :number, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [allow_empty?: true, trim?: false]

    attribute :data, :map, allow_nil?: false, sensitive?: true
  end

  relationships do
    belongs_to :release, BrusselsWtf.CBE.Index.Release do
      source_attribute :release_id
      define_attribute? false
      allow_nil? false
    end
  end
end
