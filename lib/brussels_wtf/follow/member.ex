defmodule BrusselsWtf.Follow.Member do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "follow_collection_members" do
    field :target_type, Ecto.Enum, values: [:dossier, :person, :legal_entity, :commune]
    field :target_identifier, :string
    belongs_to :collection, BrusselsWtf.Follow.Collection, type: :binary_id
    timestamps(type: :utc_datetime_usec)
  end
end
