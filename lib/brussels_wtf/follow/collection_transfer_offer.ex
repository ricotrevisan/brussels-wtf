defmodule BrusselsWtf.Follow.CollectionTransferOffer do
  @moduledoc "A short-lived, recipient-bound offer to transfer a registered collection."
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Follow,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "follow_collection_transfer_offers"
    repo BrusselsWtf.Repo
  end

  actions do
    create :offer do
      accept [:collection_id, :from_citizen_id, :to_citizen_id, :token_hash, :expires_at]
      validate compare(:from_citizen_id, is_not_equal: :to_citizen_id, attribute: true)
    end

    read :by_recipient_token do
      get? true
      argument :token_hash, :binary, allow_nil?: false, sensitive?: true
      filter expr(token_hash == ^arg(:token_hash) and to_citizen_id == ^actor(:id))
    end

    read :for_owner do
      argument :collection_id, :uuid, allow_nil?: false
      filter expr(collection_id == ^arg(:collection_id) and from_citizen_id == ^actor(:id))
    end

    read :get_for_owner do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id) and from_citizen_id == ^actor(:id))
    end

    update :accept do
      accept [:accepted_at]
      require_atomic? false
      filter expr(to_citizen_id == ^actor(:id) and is_nil(accepted_at) and is_nil(cancelled_at))
    end

    update :decline do
      accept [:cancelled_at]
      require_atomic? false
      filter expr(to_citizen_id == ^actor(:id) and is_nil(accepted_at) and is_nil(cancelled_at))
    end

    update :cancel do
      accept [:cancelled_at]
      require_atomic? false
      filter expr(from_citizen_id == ^actor(:id) and is_nil(accepted_at) and is_nil(cancelled_at))
    end

    destroy :delete_for_collection do
    end

    read :for_account_deletion do
      argument :citizen_id, :uuid, allow_nil?: false
      filter expr(from_citizen_id == ^arg(:citizen_id) or to_citizen_id == ^arg(:citizen_id))
    end

    destroy :delete_for_account do
      argument :citizen_id, :uuid, allow_nil?: false
      filter expr(from_citizen_id == ^arg(:citizen_id) or to_citizen_id == ^arg(:citizen_id))
    end
  end

  policies do
    policy action([:offer, :for_owner, :get_for_owner, :cancel]) do
      authorize_if expr(^actor(:principal) == :citizen and from_citizen_id == ^actor(:id))
    end

    policy action([:by_recipient_token, :accept, :decline]) do
      authorize_if expr(^actor(:principal) == :citizen and to_citizen_id == ^actor(:id))
    end

    policy action([:for_account_deletion, :delete_for_collection, :delete_for_account]) do
      authorize_if actor_attribute_equals(:principal, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :collection_id, :uuid, allow_nil?: false
    attribute :from_citizen_id, :uuid, allow_nil?: false
    attribute :to_citizen_id, :uuid, allow_nil?: false
    attribute :token_hash, :binary, allow_nil?: false, sensitive?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :accepted_at, :utc_datetime_usec
    attribute :cancelled_at, :utc_datetime_usec
    timestamps()
  end

  relationships do
    belongs_to :collection, BrusselsWtf.Follow.Collection do
      source_attribute :collection_id
      define_attribute? false
    end
  end

  identities do
    identity :unique_token_hash, [:token_hash]
  end
end
