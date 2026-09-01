defmodule BrusselsWtf.Follow.Collection do
  @moduledoc "An anonymous shareable collection of public targets."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Follow,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "follow_collections"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:view_token, :management_secret_hash, :title, :last_used_at]
    end

    read :by_view_token do
      get? true
      argument :view_token, :string, allow_nil?: false
      filter expr(view_token == ^arg(:view_token) and visibility != :private)
    end

    read :exchange_capability do
      get? true
      argument :management_secret_hash, :binary, allow_nil?: false, sensitive?: true
      filter expr(management_secret_hash == ^arg(:management_secret_hash))
    end

    read :manage do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
      prepare build(load: [:members])
    end

    read :owned do
      filter expr(owner_citizen_id == ^actor(:id))
    end

    read :get_for_transfer do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    read :manage_owned do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id) and owner_citizen_id == ^actor(:id))
      prepare build(load: [:members])
    end

    read :view_granted do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id) and visibility == :private and grants.citizen_id == ^actor(:id))
      prepare build(load: [:members])
    end

    update :claim do
      accept []
      argument :owner_citizen_id, :uuid, allow_nil?: false
      filter expr(is_nil(owner_citizen_id))
      validate attribute_equals(:ownership_kind, :anonymous)
      change set_attribute(:owner_citizen_id, arg(:owner_citizen_id))
      change set_attribute(:ownership_kind, :registered)
    end

    update :touch do
      accept [:last_used_at]
      require_atomic? false
    end

    update :set_visibility do
      accept [:visibility, :last_used_at]
      require_atomic? false
    end

    update :set_title do
      accept [:title, :last_used_at]
      require_atomic? false
    end

    update :transfer_owned do
      accept [:owner_citizen_id]
      argument :expected_owner_citizen_id, :uuid, allow_nil?: false
      filter expr(owner_citizen_id == ^arg(:expected_owner_citizen_id))
      require_atomic? false
    end

    destroy :delete_owned do
      filter expr(owner_citizen_id == ^actor(:id))
    end

    destroy :delete_for_account do
    end

    destroy :expire do
      primary? true
    end
  end

  policies do
    policy action([:create, :by_view_token, :exchange_capability]) do
      authorize_if always()
    end

    policy action(:claim) do
      authorize_if expr(
                     ^actor(:principal) == :citizen and
                       ^arg(:owner_citizen_id) == ^actor(:id)
                   )
    end

    policy action(:expire) do
      authorize_if actor_attribute_equals(:role, :maintenance)
    end

    policy action([:manage, :touch, :set_visibility, :set_title]) do
      authorize_if expr(id == ^actor(:collection_id))
    end

    policy action([:owned, :manage_owned, :delete_owned]) do
      authorize_if expr(^actor(:principal) == :citizen and owner_citizen_id == ^actor(:id))
    end

    policy action(:view_granted) do
      authorize_if expr(^actor(:principal) == :citizen and grants.citizen_id == ^actor(:id))
    end

    policy action([:get_for_transfer, :transfer_owned, :delete_for_account]) do
      authorize_if actor_attribute_equals(:principal, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :view_token, :string, allow_nil?: false, public?: true
    attribute :management_secret_hash, :binary, allow_nil?: false, sensitive?: true

    attribute :visibility, :atom do
      allow_nil? false
      public? true
      default :unlisted
      constraints one_of: [:public, :unlisted, :private]
    end

    attribute :owner_citizen_id, :uuid, public?: true

    attribute :ownership_kind, :atom do
      allow_nil? false
      default :anonymous
      constraints one_of: [:anonymous, :registered]
    end

    attribute :title, :string, allow_nil?: false, public?: true
    attribute :last_used_at, :utc_datetime_usec, allow_nil?: false
    timestamps()
  end

  relationships do
    has_many :members, BrusselsWtf.Follow.Member

    has_many :grants, BrusselsWtf.Follow.CollectionGrant do
      read_action :mine
    end

    has_many :transfer_offers, BrusselsWtf.Follow.CollectionTransferOffer
  end

  identities do
    identity :unique_view_token, [:view_token]
    identity :unique_management_secret_hash, [:management_secret_hash], nils_distinct?: true
  end
end
