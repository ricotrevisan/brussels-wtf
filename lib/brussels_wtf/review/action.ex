defmodule BrusselsWtf.Review.Action do
  @moduledoc "An append-only record of an authorized review action and its domain effect."

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Review,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "review_actions"
    repo BrusselsWtf.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true
      accept [:review_case_id, :action, :note, :effect, :disposition, :details]
      change BrusselsWtf.Review.Changes.SetActor
    end

    create :record_publication_resolution do
      accept [:review_case_id, :note, :details]
      change set_attribute(:action, :resolve_by_publication)
      change set_attribute(:effect, :publication_revision)
      change set_attribute(:disposition, :superseded_by_publication)
      change set_attribute(:actor_id, "system:publication")
    end
  end

  policies do
    policy action_type(:read) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :reviewer)
    end

    policy action(:record) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :reviewer)
    end

    # Written only by the publish transaction: no reviewer made this decision, so
    # it must not be recorded under a reviewer's identity.
    policy action(:record_publication_resolution) do
      authorize_if actor_absent()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :actor_id, :string, allow_nil?: false, public?: true

    attribute :action, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :retry,
                    :reclassify,
                    :relink,
                    :correct,
                    :mark_unsupported,
                    :resolve_by_publication
                  ]
    end

    attribute :effect, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :processing_generation,
                    :domain_revision,
                    :exclusion,
                    :publication_revision
                  ]
    end

    attribute :disposition, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :retry_requested,
                    :reclassified,
                    :relinked,
                    :corrected,
                    :unsupported,
                    :superseded_by_publication
                  ]
    end

    attribute :note, :string, allow_nil?: false, public?: true
    attribute :details, :map, allow_nil?: false, public?: true, default: %{}
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :review_case, BrusselsWtf.Review.Case do
      allow_nil? false
      public? true
    end
  end
end
