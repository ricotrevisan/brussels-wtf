defmodule BrusselsWtf.Follow.FeedUpdate do
  @moduledoc "An immutable, idempotent citizen-private on-site update and read state."
  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Follow,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "citizen_feed_updates"
    repo BrusselsWtf.Repo
  end

  actions do
    read :read do
      primary? true
    end

    read :mine do
      filter expr(citizen_id == ^actor(:id))
    end

    create :deliver_once do
      accept [
        :citizen_id,
        :target_type,
        :target_identifier,
        :event_identity,
        :event_kind,
        :public_url,
        :occurred_at
      ]
    end

    read :for_delivery_identity do
      argument :citizen_id, :uuid, allow_nil?: false
      argument :event_identity, :string, allow_nil?: false
      filter expr(citizen_id == ^arg(:citizen_id) and event_identity == ^arg(:event_identity))
    end

    update :mark_read do
      accept []
      change set_attribute(:read_at, &DateTime.utc_now/0)
    end

    destroy :purge do
      primary? true
    end

    read :for_account_deletion do
      argument :citizen_id, :uuid, allow_nil?: false
      filter expr(citizen_id == ^arg(:citizen_id))
    end

    destroy :delete_for_account do
      argument :citizen_id, :uuid, allow_nil?: false
      filter expr(citizen_id == ^arg(:citizen_id))
    end
  end

  policies do
    policy action([:mine, :mark_read]) do
      authorize_if expr(citizen_id == ^actor(:id) and ^actor(:principal) == :citizen)
    end

    policy action([
             :read,
             :for_delivery_identity,
             :deliver_once,
             :purge,
             :for_account_deletion,
             :delete_for_account
           ]) do
      authorize_if actor_attribute_equals(:principal, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :citizen_id, :uuid, allow_nil?: false

    attribute :target_type, :atom,
      allow_nil?: false,
      constraints: [one_of: [:dossier, :person, :legal_entity, :commune]]

    attribute :target_identifier, :string, allow_nil?: false
    attribute :event_identity, :string, allow_nil?: false
    attribute :event_kind, :atom, allow_nil?: false
    attribute :public_url, :string, allow_nil?: false
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false
    attribute :read_at, :utc_datetime_usec
    timestamps()
  end

  identities do
    identity :delivery_identity, [:citizen_id, :event_identity]
  end
end
