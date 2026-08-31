defmodule BrusselsWtf.Follow.Collection do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "follow_collections" do
    field :view_token, :string
    field :management_secret_hash, :binary
    field :visibility, Ecto.Enum, values: [:public, :unlisted, :private], default: :unlisted
    field :title, :string
    field :last_used_at, :utc_datetime_usec
    has_many :members, BrusselsWtf.Follow.Member
    timestamps(type: :utc_datetime_usec)
  end
end
